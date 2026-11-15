//
//  AppModel.swift
//  AvpCeleste64
//
//  State for the start window: whether the immersive space is open.
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
