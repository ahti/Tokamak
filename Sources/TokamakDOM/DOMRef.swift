// Copyright 2020 Tokamak contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import JavaScriptKit
import TokamakCore

extension View {
  /** Allows capturing DOM references of host views. The resulting reference is written
   to a given `binding`.
   */
  public func _domRef(_ binding: Binding<JSObjectRef?>) -> some View {
    // Convert `Binding<JSObjectRef?>` to `Binding<DOMNode?>` first.
    let targetBinding = Binding(
      get: { binding.wrappedValue.map(DOMNode.init) },
      set: { binding.wrappedValue = $0?.ref }
    )
    return _targetRef(targetBinding)
  }
}
