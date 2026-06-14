import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: TodoStore
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                if store.accountSignedOut {
                    Label("Sign in to iCloud to sync across your devices.", systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.items) { item in
                    TodoRow(item: item)
                }
                .onDelete { offsets in
                    offsets.map { store.items[$0].id }.forEach(store.delete)
                }
            }
            .navigationTitle("Todos")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Image(systemName: store.isSynced ? "checkmark.icloud" : "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(store.isSynced ? .green : .secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("New todo", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTodo)
                    Button("Add", action: addTodo)
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
                .background(.bar)
            }
        }
    }

    private func addTodo() {
        store.add(title: newTitle)
        newTitle = ""
    }
}

private struct TodoRow: View {
    @EnvironmentObject private var store: TodoStore
    let item: TodoItem
    @State private var editedTitle: String

    init(item: TodoItem) {
        self.item = item
        _editedTitle = State(initialValue: item.title)
    }

    var body: some View {
        HStack {
            Button {
                store.toggle(item.id)
            } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.completed ? .green : .secondary)
            }
            .buttonStyle(.plain)

            TextField("Title", text: $editedTitle)
                .strikethrough(item.completed)
                .onSubmit { store.rename(item.id, to: editedTitle) }
        }
    }
}
