//
//  Color+init.swift
//  Anywhere
//
//  Created by NodePassProject on 6/19/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

nonisolated extension Color {
    #if canImport(UIKit)
    var archivedData: Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: UIColor(self), requiringSecureCoding: true)
    }
    
    init?(archivedData data: Data) {
        guard let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else {
            return nil
        }
        self.init(uiColor: uiColor)
    }
    #endif
}
