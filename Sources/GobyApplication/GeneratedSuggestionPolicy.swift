/// Source changes may discard untouched suggestions, but never user edits,
/// manually added items, or items referenced by an explicit relationship.
public enum GeneratedSuggestionPolicy {
    public static func retainingCustomized<Item: Identifiable & Equatable>(
        _ items: [Item],
        suggestions: [Item.ID: Item],
        referencedIDs: Set<Item.ID>
    ) -> [Item] {
        items.filter { referencedIDs.contains($0.id) || suggestions[$0.id] != $0 }
    }
}
