public enum LifecyclePreflight {
    public static func execute<Result>(
        operation: LifecycleOperation,
        resolveNode: () async throws -> String,
        resolveType: (String) async throws -> GuestType,
        authorize: (String, GuestType) throws -> Void,
        perform: (String, GuestType) async throws -> Result
    ) async throws -> Result {
        let node = try await resolveNode()
        let type = try await resolveType(node)
        guard operation.isSupported(for: type) else {
            throw ProxmoxCtlError.unsupportedOperation(operation, type)
        }
        try authorize(node, type)
        return try await perform(node, type)
    }
}
