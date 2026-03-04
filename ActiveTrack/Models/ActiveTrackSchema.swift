import Foundation
import SwiftData

enum ActiveTrackSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ActiveInterval.self]
    }
}

enum ActiveTrackMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ActiveTrackSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
