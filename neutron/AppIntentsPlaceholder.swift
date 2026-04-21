import AppIntents

@available(macOS 13.0, *)
struct NeutronQuickOpenIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Neutron"
    static var description = IntentDescription("Opens Neutron.")

    func perform() async throws -> some IntentResult {
        .result()
    }
}
