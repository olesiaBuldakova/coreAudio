//
//  PlaybackValue.swift
//  DemoCoreAudio
//
//  Created by Леся Булдакова on 16.09.2021.
//

import Foundation

struct PlaybackValue: Identifiable {
  let value: Double
  let label: String

  var id: String {
    return "\(label)-\(value)"
  }
}
