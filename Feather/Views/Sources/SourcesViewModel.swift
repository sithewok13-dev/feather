//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON

// MARK: - Class
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]
	
	/// Custom build: re-download just these sources, skipping the local HTTP cache,
	/// and replace their entries. Used by pull-to-refresh on a source's app list.
	func refreshSources(_ sources: [AltSource]) async {
		await withTaskGroup(of: (AltSource, ASRepository?).self) { group in
			for source in sources {
				group.addTask {
					guard let url = source.sourceURL else { return (source, nil) }
					var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
					request.timeoutInterval = 30
					guard
						let (data, _) = try? await URLSession.shared.data(for: request),
						let repo = try? JSONDecoder().decode(ASRepository.self, from: data)
					else {
						return (source, nil)
					}
					return (source, repo)
				}
			}
			for await (source, repo) in group {
				if let repo {
					await MainActor.run {
						self.sources[source] = repo
					}
				}
			}
		}
	}
	
	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		guard isFinished else { return }
		
		// check if sources to be fetched are the same as before, if yes, return
		// also skip check if refresh is true
		if !refresh, sources.allSatisfy({ self.sources[$0] != nil }) { return }
		
		// isfinished is used to prevent multiple fetches at the same time
		isFinished = false
		defer { isFinished = true }
		
		// Custom build: a manual refresh must not be served from the HTTP cache.
		if refresh {
			URLCache.shared.removeAllCachedResponses()
		}
		
		await MainActor.run {
			self.sources = [:]
		}
		
		let sourcesArray = Array(sources)
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = sourcesArray[startIndex..<endIndex]
			
			let batchResults = await withTaskGroup(of: (AltSource, ASRepository?).self, returning: [AltSource: ASRepository].self) { group in
				for source in batch {
					group.addTask {
						guard let url = source.sourceURL else {
							return (source, nil)
						}
						
						return await withCheckedContinuation { continuation in
							self._dataService.fetch(from: url) { (result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (source, repo))
								case .failure(_):
									continuation.resume(returning: (source, nil))
								}
							}
						}
					}
				}
				
				var results = [AltSource: ASRepository]()
				for await (source, repo) in group {
					if let repo {
						results[source] = repo
					}
				}
				return results
			}
			
			await MainActor.run {
				for (source, repo) in batchResults {
					self.sources[source] = repo
				}
			}
		}
	}
}
