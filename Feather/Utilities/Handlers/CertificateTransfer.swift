//
//  CertificateTransfer.swift
//  Feather (custom build)
//
//  Copy a certificate (p12 + provisioning profile + password) from Feather and paste it
//  into Feather Updater. The clipboard entry stays on this device only and expires
//  after 5 minutes; pasting clears it.
//

import UIKit

enum CertificateTransfer {
	private static let _prefix = "feather-certificate:"
	
	private struct Payload: Codable {
		let p12: String
		let provision: String
		let password: String
		let nickname: String?
	}
	
	enum TransferError: LocalizedError {
		case missingFiles
		case nothingToPaste
		
		var errorDescription: String? {
			switch self {
			case .missingFiles:
				"This certificate's files could not be read."
			case .nothingToPaste:
				"No certificate on the clipboard. In the other Feather, go to Settings > Certificates, long-press your certificate and choose Copy for Feather Updater, then come back within 5 minutes."
			}
		}
	}
	
	static func copy(_ cert: CertificatePair) throws {
		guard
			let p12URL = Storage.shared.getFile(.certificate, from: cert),
			let provisionURL = Storage.shared.getFile(.provision, from: cert),
			let p12 = try? Data(contentsOf: p12URL),
			let provision = try? Data(contentsOf: provisionURL)
		else {
			throw TransferError.missingFiles
		}
		
		let payload = Payload(
			p12: p12.base64EncodedString(),
			provision: provision.base64EncodedString(),
			password: cert.password ?? "",
			nickname: cert.nickname
		)
		let json = try JSONEncoder().encode(payload)
		let text = _prefix + json.base64EncodedString()
		
		UIPasteboard.general.setItems(
			[["public.utf8-plain-text": text]],
			options: [
				.localOnly: true,
				.expirationDate: Date().addingTimeInterval(5 * 60)
			]
		)
	}
	
	static var hasPastableCertificate: Bool {
		UIPasteboard.general.string?.hasPrefix(_prefix) ?? false
	}
	
	static func paste(completion: @escaping (Error?) -> Void) {
		guard
			let text = UIPasteboard.general.string,
			text.hasPrefix(_prefix),
			let json = Data(base64Encoded: String(text.dropFirst(_prefix.count))),
			let payload = try? JSONDecoder().decode(Payload.self, from: json),
			let p12 = Data(base64Encoded: payload.p12),
			let provision = Data(base64Encoded: payload.provision)
		else {
			completion(TransferError.nothingToPaste)
			return
		}
		
		do {
			let dir = FileManager.default.temporaryDirectory
				.appendingPathComponent("CertificateTransfer-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			let p12URL = dir.appendingPathComponent("certificate.p12")
			let provisionURL = dir.appendingPathComponent("profile.mobileprovision")
			try p12.write(to: p12URL)
			try provision.write(to: provisionURL)
			
			FR.handleCertificateFiles(
				p12URL: p12URL,
				provisionURL: provisionURL,
				p12Password: payload.password,
				certificateName: payload.nickname ?? "",
				isDefault: true
			) { error in
				try? FileManager.default.removeItem(at: dir)
				if error == nil {
					// Don't leave the private key on the clipboard.
					UIPasteboard.general.items = []
				}
				completion(error)
			}
		} catch {
			completion(error)
		}
	}
}
