//
//  AppModel.swift
//  AvpCeleste64
//
//  Zustand für das Fenster: ob der ImmersiveSpace offen ist und was die Statuszeile zeigt.
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
    var statusLine = "Bereit. Stall-Probe: \(StallPlan.fromEnvironment().isEmpty ? "aus" : "an")."
    var frameLine = ""
}
