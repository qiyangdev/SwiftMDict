import Foundation
import Playgrounds
import SwiftMDict
import SwiftUI

@MainActor
private final class DictionaryDemoModel: ObservableObject {
  @Published var query = ""
  @Published private(set) var title = "Local dictionary"
  @Published private(set) var entries: [MDictEntry] = []
  @Published private(set) var selectedEntry: MDictEntry?
  @Published private(set) var definition = ""
  @Published private(set) var status = "Loading dictionary..."
  @Published private(set) var isLoading = true

  private let dictionaryURL: URL
  private var dictionary: MDict?

  init(dictionaryURL: URL) {
    self.dictionaryURL = dictionaryURL
  }

  func load() async {
    guard dictionary == nil else {
      return
    }

    isLoading = true
    status = "Loading \(dictionaryURL.lastPathComponent)..."

    do {
      let dictionary = try await MDict.open(contentsOf: dictionaryURL)
      self.dictionary = dictionary
      title = dictionary.header.title ?? dictionaryURL.lastPathComponent
      entries = Array(dictionary.entries.prefix(200))
      status = "\(dictionary.entries.count.formatted()) entries"
      isLoading = false

      if let firstEntry = entries.first {
        select(firstEntry)
      }
    } catch {
      isLoading = false
      status = "Could not load the local dictionary"
      definition = error.localizedDescription
    }
  }

  func updateSuggestions() {
    guard let dictionary else {
      return
    }

    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    entries =
      trimmedQuery.isEmpty
      ? Array(dictionary.entries.prefix(200))
      : dictionary.entries(matchingPrefix: trimmedQuery, limit: 200)
    status =
      entries.isEmpty
      ? "No entries match \"\(trimmedQuery)\""
      : "\(entries.count) matching entries"
  }

  func queryExactEntry() {
    guard let dictionary else {
      return
    }

    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      updateSuggestions()
      return
    }

    do {
      let records = try dictionary.lookup(trimmedQuery)
      entries = records.map(\.entry)
      status =
        "\(records.count) exact result\(records.count == 1 ? "" : "s")"
      if let firstEntry = entries.first {
        select(firstEntry)
      }
    } catch {
      updateSuggestions()
      if entries.isEmpty {
        definition = error.localizedDescription
      }
    }
  }

  func select(_ entry: MDictEntry) {
    guard let dictionary else {
      return
    }

    selectedEntry = entry
    do {
      let record = try dictionary.record(for: entry)
      definition =
        record.text()
        ?? "The record contains \(record.data.count.formatted()) bytes that cannot be displayed as text."
    } catch {
      definition = error.localizedDescription
    }
  }
}

private struct DictionaryDemoView: View {
  @StateObject private var model: DictionaryDemoModel

  init(dictionaryURL: URL) {
    _model = StateObject(
      wrappedValue: DictionaryDemoModel(dictionaryURL: dictionaryURL)
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      Divider()
      statusBar
    }
    .frame(minWidth: 900, minHeight: 600)
    .task {
      await model.load()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.title)
        .font(.title2.weight(.semibold))

      HStack(spacing: 8) {
        TextField("Search entries", text: $model.query)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            model.queryExactEntry()
          }
          .onChange(of: model.query) {
            model.updateSuggestions()
          }

        Button("Query") {
          model.queryExactEntry()
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(model.isLoading)
      }
    }
    .padding()
  }

  @ViewBuilder
  private var content: some View {
    if model.isLoading {
      ProgressView("Reading local MDX file...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      HSplitView {
        entryList
          .frame(minWidth: 250, idealWidth: 300)
        definitionPane
          .frame(minWidth: 450)
      }
    }
  }

  private var entryList: some View {
    List {
      ForEach(Array(model.entries.enumerated()), id: \.offset) {
        _,
        entry in
        Button {
          model.select(entry)
        } label: {
          HStack {
            Text(entry.term)
              .lineLimit(1)
            Spacer()
            Text(entry.byteCount.formatted())
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
          model.selectedEntry == entry
            ? Color.accentColor.opacity(0.16)
            : Color.clear
        )
      }
    }
    .overlay {
      if model.entries.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "text.magnifyingglass")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text("No Entries")
            .font(.headline)
          Text("Try another prefix or exact query.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
      }
    }
  }

  private var definitionPane: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(model.selectedEntry?.term ?? "Definition")
          .font(.headline)
        Spacer()
        if let byteCount = model.selectedEntry?.byteCount {
          Text("\(byteCount.formatted()) bytes")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding()

      Divider()

      ScrollView {
        Text(model.definition)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding()
      }
    }
  }

  private var statusBar: some View {
    HStack {
      Text(model.status)
      Spacer()
      Text("Showing up to 200 entries")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal)
    .frame(height: 30)
  }
}

private let localDictionaryURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appendingPathComponent("Tests", isDirectory: true)
  .appendingPathComponent("oxfordstu_no_audio", isDirectory: true)
  .appendingPathComponent("oxfordstu.mdx")

#Playground("Local MDict Browser") {
  DictionaryDemoView(dictionaryURL: localDictionaryURL)
    .frame(width: 1_000, height: 680)
}
