//
//  SourceAppsView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import UIKit

// MARK: - Extension: View (Enil)
extension SourceAppsView {
	enum SortOption: String, CaseIterable {
		case `default` = "default"
		case name
		case date
		
		var displayName: String {
			switch self {
			case .default:  .localized("Default")
			case .name: 	.localized("Name")
			case .date: 	.localized("Date")
			}
		}
	}
}

// MARK: - View
struct SourceAppsView: View {
	@AppStorage("Feather.sortOptionRawValue") private var _sortOptionRawValue: String = SortOption.default.rawValue
	@AppStorage("Feather.sortAscending") private var _sortAscending: Bool = true
	
	@State private var _sortOption: SortOption = .default
	@State private var _selectedRoute: SourceAppRoute?
	
	@State var isLoading = true
	@State var hasLoadedOnce = false
	@State private var _searchText = ""

	private var _navigationTitle: String {
		if object.count == 1 {
			object[0].name ?? .localized("Unknown")
		} else {
			.localized("%lld Sources", arguments: object.count)
		}
	}
	
	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel
	@State private var _sourceContexts: [SourceRepositoryContext]?
	@State private var _isDownloadAllPresenting = false
	@ObservedObject private var _pipeline = BulkPipeline.shared
	@State private var _pipelineViewID = UUID()
	@State private var _installPresenting: AnyApp?
	
	/// Every app in the loaded source(s) that has a download link.
	private var _downloadableApps: [(context: SourceRepositoryContext, app: ASRepository.App, url: URL)] {
		(_sourceContexts ?? []).flatMap { context in
			context.repository.apps.compactMap { app in
				guard let url = app.currentDownloadUrl else { return nil }
				return (context: context, app: app, url: url)
			}
		}
	}
	
	// MARK: Body
	var body: some View {
		ZStack {
			if
				let _sourceContexts,
				!_sourceContexts.isEmpty
			{
				SourceAppsTableRepresentableView(
					sourceContexts: _sourceContexts,
					searchText: $_searchText,
					sortOption: $_sortOption,
					sortAscending: $_sortAscending,
					onSelect: {self._selectedRoute = $0}
				)
				.ignoresSafeArea()
			} else {
				ProgressView()
			}
		}
		.navigationTitle(_navigationTitle)
		.searchable(text: $_searchText, placement: .platform())
		.toolbarTitleMenu {
			if
				let _sourceContexts,
				_sourceContexts.count == 1
			{
				if let url = _sourceContexts[0].repository.website {
					Button(.localized("Visit Website"), systemImage: "globe") {
						UIApplication.open(url)
					}
				}
				
				if let url = _sourceContexts[0].repository.patreonURL {
					Button(.localized("Visit Patreon"), systemImage: "dollarsign.circle") {
						UIApplication.open(url)
					}
				}
			}
			
			Divider()
			
			Button(.localized("Copy"), systemImage: "doc.on.doc") {
				guard !object.isEmpty else {
					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: .localized("No sources to copy")
					)
					return
				}
				UIPasteboard.general.string = object.map {
					$0.sourceURL!.absoluteString
				}.joined(separator: "\n")
				UIAlertController.showAlertWithOk(
					title: .localized("Success"),
					message: .localized("Sources copied to clipboard")
				)
			}
		}
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					_isDownloadAllPresenting = true
				} label: {
					Image(systemName: "arrow.down.circle")
				}
				.disabled(_downloadableApps.isEmpty || _pipeline.isRunning)
				.accessibilityLabel("Download All")
			}
			
			NBToolbarMenu(
				systemImage: "line.3.horizontal.decrease",
				style: .icon,
				placement: .topBarTrailing
			) {
				_sortActions()
			}
		}
		.confirmationDialog(
			"All \(_downloadableApps.count) apps in this list",
			isPresented: $_isDownloadAllPresenting,
			titleVisibility: .visible
		) {
			Button("Download All") {
				_downloadAll()
			}
			Button("Download, Sign & Install All") {
				_downloadSignInstallAll()
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text("Sign & Install uses your default certificate and signing settings. iOS asks you to approve each install.")
		}
		.overlay(alignment: .bottom) {
			if let status = _pipeline.status, _pipeline.ownerID == _pipelineViewID {
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
		.onChange(of: _pipeline.installQueue.count) { count in
			if count > 0, _installPresenting == nil, _pipeline.ownerID == _pipelineViewID {
				_installPresenting = _pipeline.popNextInstall()
			}
		}
		.sheet(item: $_installPresenting, onDismiss: _presentNextInstall) { app in
			InstallPreviewView(app: app.base, isSharing: false)
				.presentationDetents([.height(200)])
				.presentationDragIndicator(.visible)
		}
		.onAppear {
			if !hasLoadedOnce, viewModel.isFinished {
				_load()
				hasLoadedOnce = true
			}
			_sortOption = SortOption(rawValue: _sortOptionRawValue) ?? .default
		}
		.onChange(of: viewModel.isFinished) { _ in
			_load()
		}
		.onChange(of: _sortOption) { newValue in
			_sortOptionRawValue = newValue.rawValue
		}
		.navigationDestinationIfAvailable(item: $_selectedRoute) { route in
			SourceAppsDetailView(
				sourceURL: route.sourceURL,
				source: route.source,
				app: route.app
			)
		}
	}
	
	private func _downloadSignInstallAll() {
		let items = _downloadableApps.map { item in
			BulkPipeline.Item(
				id: item.app.currentUniqueId,
				url: item.url,
				provenance: SourceAppProvenance(
					sourceURL: item.context.sourceURL,
					repository: item.context.repository,
					app: item.app
				)
			)
		}
		_pipeline.downloadSignInstall(items, owner: _pipelineViewID)
	}
	
	private func _presentNextInstall() {
		guard _pipeline.ownerID == _pipelineViewID else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
			_installPresenting = _pipeline.popNextInstall()
		}
	}
	
	private func _downloadAll() {
		for item in _downloadableApps {
			_ = DownloadManager.shared.startDownload(
				from: item.url,
				id: item.app.currentUniqueId,
				sourceProvenance: SourceAppProvenance(
					sourceURL: item.context.sourceURL,
					repository: item.context.repository,
					app: item.app
				)
			)
		}
	}
	
	private func _load() {
		isLoading = true
		
		Task {
			let loadedSources = object.compactMap { source -> SourceRepositoryContext? in
				guard let repository = viewModel.sources[source] else { return nil }
				return SourceRepositoryContext(sourceURL: source.sourceURL, repository: repository)
			}
			_sourceContexts = loadedSources
			withAnimation(.easeIn(duration: 0.2)) {
				isLoading = false
			}
		}
	}
	
	struct SourceRepositoryContext: Equatable {
		let sourceURL: URL?
		let repository: ASRepository
		
		static func == (lhs: SourceRepositoryContext, rhs: SourceRepositoryContext) -> Bool {
			lhs.sourceURL == rhs.sourceURL &&
			lhs.repository.id == rhs.repository.id &&
			lhs.repository.name == rhs.repository.name &&
			lhs.repository.apps.map { "\($0.currentUniqueId)|\($0.currentVersion ?? "")" } ==
			rhs.repository.apps.map { "\($0.currentUniqueId)|\($0.currentVersion ?? "")" }
		}
	}
	
	struct SourceAppRoute: Identifiable, Hashable {
		let sourceURL: URL?
		let source: ASRepository
		let app: ASRepository.App
		let id: String = UUID().uuidString
	}
}

// MARK: - Extension: View (Sort)
extension SourceAppsView {
	@ViewBuilder
	private func _sortActions() -> some View {
		Section(.localized("Filter by")) {
			ForEach(SortOption.allCases, id: \.displayName) { opt in
				_sortButton(for: opt)
			}
		}
	}
	
	private func _sortButton(for option: SortOption) -> some View {
		Button {
			if _sortOption == option {
				_sortAscending.toggle()
			} else {
				_sortOption = option
				_sortAscending = true
			}
		} label: {
			HStack {
				Text(option.displayName)
				Spacer()
				if _sortOption == option {
					Image(systemName: _sortAscending ? "chevron.up" : "chevron.down")
				}
			}
		}
	}
}

import SwiftUI

extension View {
	@ViewBuilder
	func navigationDestinationIfAvailable<Item: Identifiable & Hashable, Destination: View>(
		item: Binding<Item?>,
		@ViewBuilder destination: @escaping (Item) -> Destination
	) -> some View {
		if #available(iOS 17, *) {
			self.navigationDestination(item: item, destination: destination)
		} else {
			self
		}
	}
}
