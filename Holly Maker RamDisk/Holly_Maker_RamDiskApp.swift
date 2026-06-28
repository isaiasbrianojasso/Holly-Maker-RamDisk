//
//  Holly_Maker_RamDiskApp.swift
//  Holly Maker RamDisk
//
//  Created by Jose Isaias Briano Jasso on 28/06/26.
//

import SwiftUI
import CoreData

@main
struct Holly_Maker_RamDiskApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
