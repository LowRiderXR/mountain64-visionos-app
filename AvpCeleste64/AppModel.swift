//
//  AppModel.swift
//  AvpCeleste64
//
//  Zustand für das Startfenster: ob der ImmersiveSpace offen ist.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    enum ImmersiveState {
        case closed
        case opening
        case open
    }

    let immersiveSpaceID = "c64-immersive"

    var immersiveState: ImmersiveState = .closed
}
