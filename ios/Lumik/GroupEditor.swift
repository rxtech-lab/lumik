import SwiftUI

struct GroupEditor: View {
  var group: ScanGroup?
  /// Set when creating a subgroup.
  var parent: ScanGroup?
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var draft: GroupDraft
  init(group: ScanGroup? = nil, parent: ScanGroup? = nil) {
    self.group = group
    self.parent = parent
    _draft = State(initialValue: GroupDraft(group: group, parent: parent))
  }
  private var title: String {
    if group != nil { return "Edit group" }
    return parent == nil ? "New group" : "New subgroup"
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Group details") {
          TextField("Group name", text: $draft.name)
          TextField("What should Lumik look for?", text: $draft.instructions, axis: .vertical)
            .lineLimit(3...6)
        }
        if let parent {
          Section {
            LabeledContent("Inside", value: parent.name)
          } footer: {
            Text(
              "Starts with the same fields and naming as \(parent.name), so PDFs keep their details when they move between the two."
            )
          }
        }
        Section {
          NavigationLink {
            SchemaEditor(schema: $draft.schema)
          } label: {
            LabeledContent(
              "Extraction schema",
              value: "\(draft.schema.object["properties"]?.object.count ?? 0) fields")
          }.accessibilityIdentifier("schema-editor-link")
        } footer: {
          Text(
            "Choose the fields to extract from every document in this group. Build your schema visually or describe it to Lumik."
          )
        }
        Section {
          Toggle("Extract other details", isOn: $draft.extractAdditional)
            .accessibilityIdentifier("extract-additional")
        } footer: {
          Text(
            "Lumik also collects anything else useful it finds in each PDF, beyond your fields, and designs a view for it. Applies to new PDFs, or to existing ones when you extract again."
          )
        }
        Section {
          TextField("Filename template", text: $draft.namingTemplate)
        } header: {
          Text("PDF naming")
        } footer: {
          Text(
            "Use {date}, {title}, or a field such as {vendor}. Example: {date}-{vendor}-{title}.pdf. New PDFs then follow the names already in this group, including ones you edited."
          )
        }
      }.formStyle(.grouped).navigationTitle(title)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              Task {
                if await store.perform(
                  "Saving group…", success: "Group saved",
                  { try await store.saveGroup(draft, id: group?.id) })
                {
                  dismiss()
                }
              }
            }.disabled(
              draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                || draft.namingTemplate.isEmpty || store.busy != nil)
          }
        }
    }
  }
}
struct SchemaEditor: View {
  @Binding var schema: JSONValue
  var reviewingDraft = false
  @State private var field: FieldDraft?
  @State private var agent = false
  @State private var raw = false
  var properties: [String: JSONValue] { schema.object["properties"]?.object ?? [:] }
  private var note: Text {
    Text(
      "Your schema is saved with the group. Updating it affects future extraction; existing results remain unchanged."
    )
  }
  private func addField() {
    Haptics.tap()
    field = FieldDraft()
  }
  private var actions: some View {
    Menu {
      Button("Add field", systemImage: "plus", action: addField)
      if !reviewingDraft {
        Button("Describe with Lumik", systemImage: "sparkles") { agent = true }
        Button("Edit JSON Schema", systemImage: "curlybraces") { raw = true }
      }
    } label: {
      #if os(macOS)
        Label("Schema actions", systemImage: "plus")
      #else
        Image(systemName: "plus.circle")
      #endif
    }.accessibilityLabel("Schema actions")
  }
  var body: some View {
    Group {
      if properties.isEmpty {
        ContentUnavailableView {
          Label("Choose your fields", systemImage: "list.bullet.rectangle")
        } description: {
          Text("Add a field, or ask Lumik to build a schema from your description.")
        } actions: {
          Button("Add field", systemImage: "plus", action: addField).buttonStyle(.borderedProminent)
        }
      } else {
        List {
          Section {
            ForEach(properties.keys.sorted(), id: \.self) { key in
              Button {
                Haptics.tap()
                field = FieldDraft(
                  name: key, schema: properties[key] ?? .object([:]),
                  required: schema.object["required"]?.array.contains(.string(key)) ?? false,
                  originalName: key)
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(key).foregroundStyle(.primary)
                    Text(properties[key]?.object["description"]?.string ?? "").font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Text(properties[key]?.object["type"]?.string ?? "mixed").font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                  Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }.padding(.vertical, 4)
              }
            }
          } footer: {
            #if os(iOS)
              note
            #endif
          }
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Extraction schema")
      #if os(macOS)
        // macOS does not show toolbar items on a screen pushed inside a sheet.
        .safeAreaInset(edge: .bottom) {
          HStack(spacing: 16) {
            note.font(.footnote).foregroundStyle(.secondary).fixedSize(
              horizontal: false, vertical: true)
            Spacer()
            actions.fixedSize()
          }.padding().background(.bar)
        }
      #else
        .toolbar { ToolbarItem(placement: .primaryAction) { actions } }
      #endif
      .sheet(item: $field) { value in
        FieldEditor(draft: value, existingNames: Set(properties.keys)) { updated in
          var root = schema.object
          var props = properties
          var required = root["required"]?.array ?? []
          if let old = value.originalName {
            props.removeValue(forKey: old)
            required.removeAll { $0 == .string(old) }
          }
          if let updated {
            props[updated.name] = updated.schema
            if updated.required { required.append(.string(updated.name)) }
          }
          root["properties"] = .object(props)
          root["required"] = .array(required)
          schema = .object(root)
        }.fullSheet()
      }
      .sheet(isPresented: $agent) { SchemaAgentView { schema = $0 }.fullSheet().actionFeedback() }
      .sheet(isPresented: $raw) {
        JSONEditor(title: "JSON Schema", value: schema) { schema = $0 }.fullSheet()
      }
  }
}
struct FieldDraft: Identifiable {
  var id = UUID()
  var name = ""
  var schema: JSONValue = .object(["type": .string("string"), "description": .string("")])
  var required = true
  var originalName: String?
}
struct FieldEditor: View {
  @State var draft: FieldDraft
  let existingNames: Set<String>
  let save: (FieldDraft?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var confirmDelete = false
  var type: String { draft.schema.object["type"]?.string ?? "string" }
  func property(_ key: String) -> Binding<String> {
    Binding(
      get: { draft.schema.object[key]?.string ?? "" },
      set: {
        var obj = draft.schema.object
        obj[key] = .string($0)
        draft.schema = .object(obj)
      })
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Field") {
          TextField("Name, e.g. invoice_number", text: $draft.name)
          TextField("Description", text: property("description"), axis: .vertical)
          Picker("Type", selection: property("type")) {
            ForEach(["string", "number", "integer", "boolean", "object", "array"], id: \.self) {
              Text($0.capitalized).tag($0)
            }
          }
          Toggle("Required", isOn: $draft.required)
        }
        if type == "object" {
          NavigationLink("Nested fields") { SchemaEditor(schema: $draft.schema) }
        }
        if type == "array" {
          Section("Array items") {
            Picker(
              "Item type",
              selection: Binding(
                get: { draft.schema.object["items"]?.object["type"]?.string ?? "string" },
                set: {
                  var obj = draft.schema.object
                  obj["items"] = $0 == "object" ? .emptySchema : .object(["type": .string($0)])
                  draft.schema = .object(obj)
                })
            ) {
              ForEach(["string", "number", "integer", "boolean", "object"], id: \.self) {
                Text($0.capitalized).tag($0)
              }
            }
            if draft.schema.object["items"]?.object["type"]?.string == "object" {
              NavigationLink("Item fields") {
                SchemaEditor(
                  schema: Binding(
                    get: { draft.schema.object["items"] ?? .emptySchema },
                    set: {
                      var obj = draft.schema.object
                      obj["items"] = $0
                      draft.schema = .object(obj)
                    }))
              }
            }
          }
        }
        if draft.originalName != nil {
          Section { Button("Remove field", role: .destructive) { confirmDelete = true } }
        }
      }.formStyle(.grouped).navigationTitle(draft.originalName == nil ? "Add field" : "Edit field")
        .onChange(of: type) { _, new in
          var obj = draft.schema.object
          obj.removeValue(forKey: "items")
          obj.removeValue(forKey: "properties")
          obj.removeValue(forKey: "required")
          obj.removeValue(forKey: "additionalProperties")
          if new == "object" { obj.merge(JSONValue.emptySchema.object) { _, new in new } }
          if new == "array" { obj["items"] = .object(["type": .string("string")]) }
          draft.schema = .object(obj)
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
              save(draft)
              Haptics.success()
              dismiss()
            }.disabled(
              draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (existingNames.contains(draft.name) && draft.name != draft.originalName)
            )
            .accessibilityIdentifier("save-field")
          }
        }
        .confirmationDialog("Remove this field?", isPresented: $confirmDelete) {
          Button("Remove", role: .destructive) {
            save(nil)
            Haptics.tap()
            dismiss()
          }
        }
    }
  }
}
struct SchemaAgentView: View {
  let apply: (JSONValue) -> Void
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var prompt = ""
  @State private var result: JSONValue?
  @State private var reviewing = false
  @State private var draftedPrompt = ""

  private func next() {
    Haptics.tap()
    if result != nil && draftedPrompt == prompt {
      reviewing = true
      return
    }
    Task {
      let description = prompt
      if await store.perform("Drafting fields…", success: "Fields ready to review", {
        result = try await store.fetch(
          JSONValue.self, "schema/draft", method: "POST",
          body: JSONEncoder().encode(["prompt": description]))
      }) {
        draftedPrompt = description
        reviewing = true
      }
    }
  }

  var body: some View {
    NavigationStack {
      Group {
        if reviewing {
          SchemaEditor(
            schema: Binding(get: { result ?? .emptySchema }, set: { result = $0 }),
            reviewingDraft: true)
        } else {
          Form {
            Section {
              TextEditor(text: $prompt)
                .frame(minHeight: 150)
                .accessibilityLabel("Information to extract")
            } header: {
              Text("Describe the information you need")
            } footer: {
              Text("For example: For invoices, capture the vendor, invoice date, total, currency, and each line item. Next, review the fields before applying them.")
            }
          }.formStyle(.grouped)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(reviewing ? "Review fields" : "Ask Lumik")
      .safeAreaInset(edge: .bottom) {
        HStack {
          if reviewing {
            Button("Back") {
              Haptics.tap()
              reviewing = false
            }
          }
          Spacer()
          Button("Cancel") { dismiss() }
          if reviewing {
            Button("Use fields") {
              if let result {
                apply(result)
                Haptics.success()
                dismiss()
              }
            }.buttonStyle(.borderedProminent)
          } else {
            Button("Draft fields", systemImage: "sparkles", action: next)
              .buttonStyle(.borderedProminent)
              .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).count < 5)
          }
        }.padding().background(.bar)
      }
      .disabled(store.busy != nil)
    }
  }
}

struct JSONEditor: View {
  let title: String
  let save: (JSONValue) -> Void
  @State private var text: String
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss
  init(title: String, value: JSONValue, save: @escaping (JSONValue) -> Void) {
    self.title = title
    self.save = save
    _text = State(initialValue: value.pretty)
  }
  var body: some View {
    NavigationStack {
      TextEditor(text: $text).font(.body.monospaced()).padding().navigationTitle(title).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              let value = try JSONValue.parse(text)
              guard case .object = value else { throw APIError(message: "Enter a JSON object.") }
              save(value)
              Haptics.success()
              dismiss()
            } catch { if !isSilentCancellation(error) { self.error = error.localizedDescription } }
          }
        }
      }.alert(
        "Invalid JSON", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK") { error = nil }
      } message: {
        Text(error ?? "")
      }
    }
  }
}
