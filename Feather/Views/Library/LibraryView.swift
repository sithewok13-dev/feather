//
//  ContentView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import NimbleViews

// MARK: - View
struct LibraryView: View {
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject var updateManager = UpdateManager.shared
	
	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false
	@State private var _alertDownloadString: String = "" // for _isDownloadingPresenting
	@State private var _updateCheckRotation = 0.0
	@State private var _isUpdateCheckCompleteVisible = false
	
	// MARK: Selection State
	@State private var _selectedAppUUIDs: Set<String> = []
	@State private var _editMode: EditMode = .inactive
	@State private var _isBulkDeleteConfirmPresenting = false
	@State private var _bulkSignStatus: String?
	@State private var _bulkInstallQueue: [AnyApp] = []
	
	@State private var _searchText = ""
	@State private var _selectedScope: Scope = .all
	
	
	@Namespace private var _namespace
	
	// horror
	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {
		apps.filter {
			_searchText.isEmpty ||
				(($0.value(forKey: "name") as? String)?.localizedCaseInsensitiveContains(_searchText) ?? false)
		}
	}
	
	private var _filteredSignedApps: [Signed] {
		filteredAndSortedApps(from: _signedApps)
	}
	
	private var _filteredImportedApps: [Imported] {
		filteredAndSortedApps(from: _importedApps)
	}
	
	// MARK: Fetch
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>
	
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Library")) {
			NBListAdaptable {
				if
					!_filteredSignedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .signed
				{
					NBSection(
						.localized("Signed"),
						secondary: _filteredSignedApps.count.description
					) {
						ForEach(_filteredSignedApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								selectedInfoAppPresenting: $_selectedInfoAppPresenting,
								selectedSigningAppPresenting: $_selectedSigningAppPresenting,
								selectedInstallAppPresenting: $_selectedInstallAppPresenting,
								selectedAppUUIDs: $_selectedAppUUIDs
							)
							.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						}
					}
				}
				
				if
					!_filteredImportedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .imported
				{
					NBSection(
						.localized("Imported"),
						secondary: _filteredImportedApps.count.description
					) {
						ForEach(_filteredImportedApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								selectedInfoAppPresenting: $_selectedInfoAppPresenting,
								selectedSigningAppPresenting: $_selectedSigningAppPresenting,
								selectedInstallAppPresenting: $_selectedInstallAppPresenting,
								selectedAppUUIDs: $_selectedAppUUIDs
							)
							.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						}
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform())
			.compatSearchScopes($_selectedScope) {
				ForEach(Scope.allCases, id: \.displayName) { scope in
					Text(scope.displayName).tag(scope)
				}
			}
			.scrollDismissesKeyboard(.interactively)
			.overlay {
				if
					_filteredSignedApps.isEmpty,
					_filteredImportedApps.isEmpty
				{
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(.localized("No Apps"), systemImage: "questionmark.app.fill")
						} description: {
							Text(.localized("Get started by importing your first IPA file."))
						} actions: {
							Menu {
								_importActions()
							} label: {
								NBButton(.localized("Import"), style: .text)
							}
						}
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					EditButton()
				}
				
				if _editMode.isEditing {
					ToolbarItem(placement: .topBarLeading) {
						Button {
							_toggleSelectAll()
						} label: {
							Image(systemName: _areAllVisibleAppsSelected ? "checkmark.circle.fill" : "circle.dashed")
						}
						.disabled(_getAllApps().isEmpty)
						.accessibilityLabel(_areAllVisibleAppsSelected ? "Deselect All" : "Select All")
					}
					
					ToolbarItem(placement: .topBarTrailing) {
						Menu {
							Button("Sign Selected (\(_selectedImportedApps.count))", systemImage: "signature") {
								_bulkSignSelected()
							}
							.disabled(_selectedImportedApps.isEmpty)
							
							Button("Install Selected (\(_selectedSignedApps.count))", systemImage: "square.and.arrow.down") {
								_bulkInstallSelected()
							}
							.disabled(_selectedSignedApps.isEmpty)
						} label: {
							Image(systemName: "ellipsis.circle")
						}
						.disabled(_selectedAppUUIDs.isEmpty || _bulkSignStatus != nil)
					}
					
					NBToolbarButton(
						.localized("Delete"),
						systemImage: "trash",
						isDisabled: _selectedAppUUIDs.isEmpty
					) {
						_isBulkDeleteConfirmPresenting = true
					}
				} else {
					ToolbarItem(placement: .topBarTrailing) {
						Button {
							Task {
								await _checkForUpdates()
							}
						} label: {
							Image(systemName: _isUpdateCheckCompleteVisible ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
								.rotationEffect(.degrees(_updateCheckRotation))
								.animation(
									updateManager.isChecking
										? .linear(duration: 0.8).repeatForever(autoreverses: false)
										: .default,
									value: _updateCheckRotation
								)
						}
						.disabled(updateManager.isChecking)
						.accessibilityLabel(.localized("Check for Updates"))
					}
					
					NBToolbarMenu(
						systemImage: "plus",
						style: .icon,
						placement: .topBarTrailing
					) {
						_importActions()
					}
				}
			}
			.environment(\.editMode, $_editMode)
			.alert(
				"Delete \(_selectedAppUUIDs.count) app(s)?",
				isPresented: $_isBulkDeleteConfirmPresenting
			) {
				Button(.localized("Cancel"), role: .cancel) {}
				Button(.localized("Delete"), role: .destructive) {
					_bulkDeleteSelectedApps()
				}
			} message: {
				Text("This removes the selected signed and imported apps from Feather. It cannot be undone.")
			}
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.overlay(alignment: .bottom) {
				if let status = _bulkSignStatus {
					HStack(spacing: 8) {
						ProgressView()
						Text(status)
					}
					.padding(.horizontal, 16)
					.padding(.vertical, 10)
					.background(.regularMaterial, in: Capsule())
					.padding(.bottom, 100)
				}
			}
			.sheet(item: $_selectedInstallAppPresenting, onDismiss: _presentNextQueuedInstall) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						
						for url in urls {
							let id = "FeatherManualDownload_\(UUID().uuidString)"
							let dl = downloadManager.startArchive(from: url, id: id)
							try? downloadManager.handlePachageFile(url: url, dl: dl)
						}
					}
				)
				.ignoresSafeArea()
			}
			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
				TextField(.localized("URL"), text: $_alertDownloadString)
					.textInputAutocapitalization(.never)
				Button(.localized("Cancel"), role: .cancel) {
					_alertDownloadString = ""
				}
				Button(.localized("OK")) {
					if let url = URL(string: _alertDownloadString) {
						_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installApp"))) { _ in
				if let latest = _signedApps.first {
					_selectedInstallAppPresenting = AnyApp(base: latest)
				}
			}
			.onChange(of: _editMode) { mode in
				if mode == .inactive {
					_selectedAppUUIDs.removeAll()
				}
			}
			.onChange(of: updateManager.isChecking) { isChecking in
				_handleUpdateCheckStateChange(isChecking)
			}
		}
	}
}

// MARK: - Extension: View
extension LibraryView {
	@ViewBuilder
	private func _importActions() -> some View {
		Button(.localized("Import from Files"), systemImage: "folder") {
			_isImportingPresenting = true
		}
		Button(.localized("Import from URL"), systemImage: "globe") {
			_isDownloadingPresenting = true
		}
	}
}

// MARK: - Extension: Bulk Delete
extension LibraryView {
	private func _bulkDeleteSelectedApps() {
		let selectedApps = _getAllApps().filter { app in
			guard let uuid = app.uuid else { return false }
			return _selectedAppUUIDs.contains(uuid)
		}
		
		for app in selectedApps {
			Storage.shared.deleteApp(for: app)
		}
		
		_selectedAppUUIDs.removeAll()
		
		// _editMode = .inactive
	}
	
	private var _selectedImportedApps: [Imported] {
		_filteredImportedApps.filter { _selectedAppUUIDs.contains($0.uuid ?? "") }
	}
	
	private var _selectedSignedApps: [Signed] {
		_filteredSignedApps.filter { _selectedAppUUIDs.contains($0.uuid ?? "") }
	}
	
	// MARK: Bulk Sign
	/// Signs every selected imported app, one after another, with the default
	/// certificate and the default signing options (same as tapping Sign without changes).
	private func _bulkSignSelected() {
		let apps = _selectedImportedApps
		guard !apps.isEmpty else { return }
		
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		let cert: CertificatePair? = _certificates.indices.contains(storedCert) ? _certificates[storedCert] : nil
		
		guard cert != nil || OptionsManager.shared.options.signingOption != .default else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate")
			)
			return
		}
		
		_editMode = .inactive
		_signNext(apps, index: 0, cert: cert, failures: [])
	}
	
	private func _signNext(_ apps: [Imported], index: Int, cert: CertificatePair?, failures: [String]) {
		guard index < apps.count else {
			_bulkSignStatus = nil
			let signed = apps.count - failures.count
			var message = "Signed \(signed) of \(apps.count) app(s). They are now under Signed."
			if !failures.isEmpty {
				message += "\n\nFailed:\n" + failures.joined(separator: "\n")
			}
			UIAlertController.showAlertWithOk(title: "Sign Selected", message: message)
			return
		}
		
		let app = apps[index]
		_bulkSignStatus = "Signing \(index + 1) of \(apps.count)…"
		
		// Same per-app adjustments SigningView applies when it opens.
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
		
		FR.signPackageFile(app, using: options, icon: nil, certificate: cert) { error in
			var failures = failures
			if let error {
				failures.append("\(app.name ?? "Unknown"): \(error.localizedDescription)")
			} else if options.post_deleteAppAfterSigned {
				Storage.shared.deleteApp(for: app)
			}
			_signNext(apps, index: index + 1, cert: cert, failures: failures)
		}
	}
	
	// MARK: Bulk Install
	/// Queues every selected signed app. Each one opens the normal install sheet;
	/// closing the sheet starts the next app in the queue. Feather itself is skipped.
	private func _bulkInstallSelected() {
		let ownId = Bundle.main.bundleIdentifier
		let apps = _selectedSignedApps.filter { $0.identifier != ownId }
		guard !apps.isEmpty else { return }
		
		_bulkInstallQueue = apps.map { AnyApp(base: $0) }
		_editMode = .inactive
		_presentNextQueuedInstall()
	}
	
	private func _presentNextQueuedInstall() {
		guard !_bulkInstallQueue.isEmpty else { return }
		let next = _bulkInstallQueue.removeFirst()
		// Give the previous sheet time to finish dismissing.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
			_selectedInstallAppPresenting = next
		}
	}
	
	private var _visibleAppUUIDs: Set<String> {
		Set(_getAllApps().compactMap { $0.uuid })
	}
	
	private var _areAllVisibleAppsSelected: Bool {
		let visible = _visibleAppUUIDs
		return !visible.isEmpty && visible.isSubset(of: _selectedAppUUIDs)
	}
	
	/// Selects every app currently shown (Signed + Imported, respecting search and scope),
	/// or clears the selection if everything is already selected.
	private func _toggleSelectAll() {
		if _areAllVisibleAppsSelected {
			_selectedAppUUIDs.removeAll()
		} else {
			_selectedAppUUIDs = _visibleAppUUIDs
		}
	}
	
	private func _getAllApps() -> [AppInfoPresentable] {
		var allApps: [AppInfoPresentable] = []
		
		if _selectedScope == .all || _selectedScope == .signed {
			allApps.append(contentsOf: _filteredSignedApps)
		}
		
		if _selectedScope == .all || _selectedScope == .imported {
			allApps.append(contentsOf: _filteredImportedApps)
		}
		
		return allApps
	}
	
	private func _checkForUpdates() async {
		let localApps = _signedApps.map { $0 as AppInfoPresentable } + _importedApps.map { $0 as AppInfoPresentable }
		await updateManager.checkForUpdates(
			sources: Array(_sources),
			localApps: localApps
		)
	}
	
	private func _handleUpdateCheckStateChange(_ isChecking: Bool) {
		if isChecking {
			_isUpdateCheckCompleteVisible = false
			_updateCheckRotation = 0
			withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
				_updateCheckRotation = 360
			}
		} else {
			withAnimation(.none) {
				_updateCheckRotation = 0
			}
			
			_isUpdateCheckCompleteVisible = true
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 900_000_000)
				if !updateManager.isChecking {
					_isUpdateCheckCompleteVisible = false
				}
			}
		}
	}
}

// MARK: - Extension: View (Sort)
extension LibraryView {
	enum Scope: CaseIterable {
		case all
		case signed
		case imported
		
		var displayName: String {
			switch self {
			case .all: return .localized("All")
			case .signed: return .localized("Signed")
			case .imported: return .localized("Imported")
			}
		}
	}
}
