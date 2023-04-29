// Copyright 2023 Tokamak contributors
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
//
//  Created by Lukas Stabe on 2023-05-01.
//

extension FiberReconciler.Fiber {
  enum Identity: Hashable {
    case explicit(AnyHashable)
    case structural(Int)
  }

  private var specifiedId: AnyHashable? {
    guard case let .view(ident as _AnyIDView, _) = content else { return nil }
    return ident.anyId
  }

  var mappedChildren: [Identity: FiberReconciler.Fiber] {
    var map = [Identity: FiberReconciler.Fiber]()
    var currentIndex = 0
    var currentChild = child

    while let aChild = currentChild {
      if let id = aChild.specifiedId {
        map[.explicit(id)] = aChild
      } else {
        map[.structural(currentIndex)] = aChild
      }

      currentIndex += 1
      currentChild = aChild.sibling
    }

    return map
  }
}
