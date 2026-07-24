public enum GuestListPlanner {
    public static func nodeNames(
        explicitNode: String?,
        inventory: [NodeSummary]?
    ) throws -> [String] {
        if let explicitNode {
            return [explicitNode]
        }

        let onlineNodes = (inventory ?? [])
            .filter { $0.status == "online" }
            .map(\.node)
        guard !onlineNodes.isEmpty else {
            throw ProxmoxCtlError.noOnlineNodes
        }
        return onlineNodes
    }
}
