//
//  ReflectionSettingsView.swift
//  Anywhere
//
//  Created by NodePassProject on 5/31/26.
//

import SwiftUI

private struct ReflectionRouteDraft: Identifiable, Equatable {
    let id = UUID()
    var value: String
}

struct ReflectionSettingsView: View {
    @Environment(\.editMode) private var editMode
    @Environment(AppSettings.self) private var settings

    @State private var routeDrafts: [ReflectionRouteDraft] = []

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Reflection", isOn: $settings.reflectionEnabled)
            } footer: {
                Text("Packets sent to a reflection route are returned to their sender instead of being routed or proxied.")
            }

            if settings.reflectionEnabled {
                Section {
                    if routeDrafts.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($routeDrafts) { $draft in
                            if isEditing {
                                TextField(String("10.7.0.1/32"), text: $draft.value)
                                    .keyboardType(.numbersAndPunctuation)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            } else {
                                HStack {
                                    Text(draft.value)
                                    if IPRoute(reflection: draft.value.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                                        Spacer()
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            routeDrafts.remove(atOffsets: offsets)
                            if editMode?.wrappedValue.isEditing != true {
                                save()
                            }
                        }
                        .onMove { source, destination in
                            routeDrafts.move(fromOffsets: source, toOffset: destination)
                            if editMode?.wrappedValue.isEditing != true {
                                save()
                            }
                        }
                    }
                } header: {
                    Text("Reflection Routes")
                } footer: {
                    Text("Each route must be /24 or narrower (/120 for IPv6) and must not contain the tunnel address.")
                }
            }
        }
        .navigationTitle("Reflection")
        .toolbar {
            if settings.reflectionEnabled {
                ToolbarItem {
                    EditButton()
                }
            }
        }
        .onAppear { loadInitial() }
        .onChange(of: isEditing) { _, newValue in
            if newValue {
                ensureTrailingBlankDraft()
            } else {
                save()
            }
        }
        .onChange(of: routeDrafts) {
            if isEditing {
                ensureTrailingBlankDraft()
            }
        }
    }

    private func loadInitial() {
        routeDrafts = settings.reflectionRoutes.map { ReflectionRouteDraft(value: $0) }
    }
    
    private func ensureTrailingBlankDraft() {
        if routeDrafts.last?.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true {
            routeDrafts.append(ReflectionRouteDraft(value: ""))
        }
    }
    
    private func save() {
        routeDrafts = routeDrafts
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        settings.reflectionRoutes = routeDrafts
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
