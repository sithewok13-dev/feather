//
//  BulkPipeline.swift
//  Feather (custom build)
//
//  Download -> sign -> install a batch of source apps with one tap.
//

import Foundation
import CoreData
import UIKit

@MainActor
final class BulkPipeline: ObservableObject {
	static let shared = BulkPipeline()
	
	struct Item {
		let id: String
		let url: URL
		let provenance: SourceAppProvenance?
	}
	
	/// Progress text while running; nil when idle.
	@Published var status: String?
	/// Signed apps waiting to be installed, consumed by the view that started the run.
	@Published var installQueue: [AnyApp] = []
	/// Which view started the run (only that view presents the install sheets).
	@Published var ownerID: UUID?
	
	var isRunning: Bool { status != nil }
	
	// MARK: Core Data helpers
	private func _fetch(_ entity: String) -> [NSManagedObject] {
		let request = NSFetchRequest<NSManagedObject>(entityName: entity)
		request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}
	
	private func _uuids(_ entity: String) -> Set<String> {
		Set(_fetch(entity).compactMap { $0.value(forKey: "uuid") as? String })
	}
	
	/// The certificate selected in Settings (same lookup SigningView uses).
	func defaultCertificate() -> CertificatePair? {
		let certs = _fetch("CertificatePair").compactMap { $0 as? CertificatePair }
		let index = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		return certs.indices.contains(index) ? certs[index] : nil
	}
	
	// MARK: Run
	func downloadSignInstall(_ items: [Item], owner: UUID) {
		guard !isRunning, !items.isEmpty else { return }
		
		let cert = defaultCertificate()
		guard cert != nil || OptionsManager.shared.options.signingOption != .default else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate")
			)
			return
		}
		
		ownerID = owner
		installQueue = []
		let importedBefore = _uuids("Imported")
		let ids = Set(items.map { $0.id })
		
		for item in items {
			_ = DownloadManager.shared.startDownload(
				from: item.url,
				id: item.id,
				sourceProvenance: item.provenance
			)
		}
		status = items.count == 1 ? "Downloading…" : "Downloading \(items.count) apps…"
		
		Task { @MainActor in
			// Wait until every download has finished and been imported (or failed).
			try? await Task.sleep(nanoseconds: 1_000_000_000)
			while true {
				let remaining = DownloadManager.shared.downloads.filter { ids.contains($0.id) }.count
				if remaining == 0 { break }
				self.status = "Downloading… \(items.count - remaining) of \(items.count) done"
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
			try? await Task.sleep(nanoseconds: 1_000_000_000)
			
			let newImported = self._fetch("Imported")
				.compactMap { $0 as? Imported }
				.filter { !importedBefore.contains($0.uuid ?? "") }
			
			guard !newImported.isEmpty else {
				self.status = nil
				UIAlertController.showAlertWithOk(
					title: "Download, Sign & Install",
					message: "No new apps were imported, so there is nothing to sign."
				)
				return
			}
			
			let signedBefore = self._uuids("Signed")
			var failures: [String] = []
			
			for (index, app) in newImported.enumerated() {
				self.status = "Signing \(index + 1) of \(newImported.count)…"
				if let error = await self._sign(app, cert: cert) {
					failures.append("\(app.name ?? "Unknown"): \(error.localizedDescription)")
				}
			}
			try? await Task.sleep(nanoseconds: 1_000_000_000)
			
			let ownId = Bundle.main.bundleIdentifier
			let newSigned = self._fetch("Signed")
				.compactMap { $0 as? Signed }
				.filter { !signedBefore.contains($0.uuid ?? "") }
				// Feather itself goes last: installing it closes the app.
				.sorted { ($0.identifier == ownId ? 1 : 0) < ($1.identifier == ownId ? 1 : 0) }
			
			self.status = nil
			
			if !failures.isEmpty {
				UIAlertController.showAlertWithOk(
					title: "Download, Sign & Install",
					message: "Some apps failed to sign and will be skipped:\n" + failures.joined(separator: "\n")
				)
			}
			
			self.installQueue = newSigned.map { AnyApp(base: $0) }
		}
	}
	
	func popNextInstall() -> AnyApp? {
		guard !installQueue.isEmpty else {
			ownerID = nil
			return nil
		}
		return installQueue.removeFirst()
	}
	
	// MARK: Sign one app with default options (same adjustments SigningView applies)
	private func _sign(_ app: Imported, cert: CertificatePair?) async -> Error? {
		var options = OptionsManager.shared.options
		if
			options.ppqProtection,
			let identifier = app.identifier,
			let cert,
			cert.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(options.ppqString)"
		}
		if
			let currentBundleId = app.identifier,
			let newBundleId = options.identifiers[currentBundleId]
		{
			options.appIdentifier = newBundleId
		}
		if
			let currentName = app.name,
			let newName = options.displayNames[currentName]
		{
			options.appName = newName
		}
		
		let deleteAfter = options.post_deleteAppAfterSigned
		let error: Error? = await withCheckedContinuation { continuation in
			FR.signPackageFile(app, using: options, icon: nil, certificate: cert) { error in
				continuation.resume(returning: error)
			}
		}
		if error == nil, deleteAfter {
			Storage.shared.deleteApp(for: app)
		}
		return error
	}
}
