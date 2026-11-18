import SwiftUI

extension View {
    /// Asks before a recording is deleted. iOS colours the sheet's Cancel with
    /// the tint where the dialog is attached, and the app's orange-red accent
    /// made it look as red as Delete; so the dialog hangs off its own clear
    /// layer with a neutral tint, leaving the screen's tint alone.
    func deleteConfirmation<Item>(
        isPresented: Binding<Bool>,
        presenting item: Item?,
        delete: @escaping (Item) -> Void
    ) -> some View {
        background {
            Color.clear
                .confirmationDialog(
                    IOSAppStrings.Recording.deleteTitle,
                    isPresented: isPresented,
                    titleVisibility: .visible,
                    presenting: item
                ) { item in
                    Button(IOSAppStrings.Recording.delete, role: .destructive) { delete(item) }
                } message: { _ in
                    Text(IOSAppStrings.Recording.deleteMessage)
                }
                .tint(Color(.label))
        }
    }
}
