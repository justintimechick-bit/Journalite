import CoreData
import Foundation

enum PersistenceError: Error {
    case missingModel
    case missingRecord
    case invalidRecord
    case notLoaded
}

/// Owns one local store. No CloudKit container or service is initialized.
@MainActor
final class PersistenceController {
    enum Location {
        case application
        case sqlite(URL)
        case memory
    }

    private let location: Location
    private(set) var container: NSPersistentContainer?
    private(set) var storeURL: URL?

    init(location: Location = .application) {
        self.location = location
    }

    func load() async throws {
        guard container == nil else { return }
        guard let modelURL = Bundle.main.url(forResource: "JournalModel", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent("JournalModelV3.mom")),
              model.entitiesByName["JournalEntry"]?.attributesByName["pendingIngestionID"] != nil,
              model.entitiesByName["JournalPage"]?.attributesByName["ocrImageVersion"] != nil else {
            throw PersistenceError.missingModel
        }
        let candidate = NSPersistentContainer(name: "JournalModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        switch location {
        case .application:
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Journalite", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storeURL = directory.appendingPathComponent("Journalite.sqlite")
            description.url = storeURL
            description.type = NSSQLiteStoreType
        case .sqlite(let url):
            storeURL = url
            description.url = url
            description.type = NSSQLiteStoreType
        case .memory:
            description.type = NSInMemoryStoreType
        }
        description.cloudKitContainerOptions = nil
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = true
        if description.type == NSSQLiteStoreType {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        }
        candidate.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            candidate.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        candidate.viewContext.automaticallyMergesChangesFromParent = true
        container = candidate
    }

    func repository() throws -> JournalRepository {
        guard let container else { throw PersistenceError.notLoaded }
        return JournalRepository(container: container)
    }

    /// Close only after callers finish their operations; never destroys store files.
    func close() throws {
        guard let container else { return }
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        self.container = nil
    }
}
