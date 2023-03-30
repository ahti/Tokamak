// Copyright 2022 Tokamak contributors
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
//  Created by Carson Katri on 5/28/22.
//

import Foundation

enum SlotIndex: Hashable {
  case index(Int)
  case id(AnyHashable)
}

extension FiberReconciler.Fiber {
  private var id: AnyHashable? {
    guard case let .view(v, _) = content,
          let ident = v as? _AnyIDView
      else { return nil }
    return ident.anyId
  }
  var mappedChildren: [SlotIndex: FiberReconciler.Fiber] {
    var map = [SlotIndex: FiberReconciler.Fiber]()

    var currentIndex = 0
    var currentChild = child
    while let aChild = currentChild {
      if let id = aChild.id {
        map[.id(id)] = aChild
      } else {
        map[.index(currentIndex)] = aChild
      }
      currentIndex += 1
      currentChild = aChild.sibling
    }

    return map
  }
}

extension FiberReconciler {
  /// Convert the first level of children of a `View` into a linked list of `Fiber`s.
  struct TreeReducer: SceneReducer {
    final class Result {
      // For references
      let fiber: Fiber?
      let visitChildren: (TreeReducer.SceneVisitor) -> ()
      unowned var parent: Result?
      var child: Result?
      var sibling: Result?
      var nextTraits: _ViewTraitStore

      // For reducing
      var lastSibling: Result?
      var processedChildCount: Int
      var unclaimedCurrentChildren: [SlotIndex: Fiber]

      // Side-effects
      var didInsert: Bool
      var newContent: Renderer.ElementType.Content?
//      var deletions: [Fiber]

      init(
        fiber: Fiber?,
        currentChildren: [SlotIndex: Fiber],
        visitChildren: @escaping (TreeReducer.SceneVisitor) -> (),
        parent: Result?,
        newContent: Renderer.ElementType.Content? = nil,
        nextTraits: _ViewTraitStore
      ) {
        self.fiber = fiber
        self.visitChildren = visitChildren
        self.parent = parent
        self.nextTraits = nextTraits

        processedChildCount = 0
        unclaimedCurrentChildren = currentChildren

        didInsert = false
        self.newContent = nil
      }
    }

    static func reduce<S>(into partialResult: inout Result, nextScene: S) where S: Scene {
      Self.reduce(
        into: &partialResult,
        nextValue: nextScene,
        createFiber: { scene, element, parent, elementParent, preferenceParent, _, _, reconciler in
          Fiber(
            &scene,
            element: element,
            parent: parent,
            elementParent: elementParent,
            preferenceParent: preferenceParent,
            environment: nil,
            reconciler: reconciler
          )
        },
        update: { fiber, scene, _, _ in
          fiber.update(with: &scene)
        },
        visitChildren: { $1._visitChildren }
      )
    }

    static func reduce<V>(into partialResult: inout Result, nextView: V) where V: View {
      Self.reduce(
        into: &partialResult,
        nextValue: nextView,
        createFiber: {
          view, element,
            parent, elementParent, preferenceParent, elementIndex,
            traits, reconciler in
          Fiber(
            &view,
            element: element,
            parent: parent,
            elementParent: elementParent,
            preferenceParent: preferenceParent,
            elementIndex: elementIndex,
            traits: traits,
            reconciler: reconciler
          )
        },
        update: { fiber, view, elementIndex, traits in
          fiber.update(
            with: &view,
            elementIndex: elementIndex,
            traits: fiber.element != nil ? traits : nil
          )
        },
        visitChildren: { reconciler, view in
          reconciler?.renderer.viewVisitor(for: view) ?? view._visitChildren
        }
      )
    }

    static func reduce<T>(
      into partialResult: inout Result,
      nextValue: T,
      createFiber: (
        inout T,
        Renderer.ElementType?,
        Fiber?,
        Fiber?,
        Fiber?,
        Int?,
        _ViewTraitStore,
        FiberReconciler?
      ) -> Fiber,
      update: (Fiber, inout T, Int?, _ViewTraitStore) -> Renderer.ElementType.Content?,
      visitChildren: (FiberReconciler?, T) -> (TreeReducer.SceneVisitor) -> ()
    ) {
      // Create the node and its element.
      var nextValue = nextValue

      let nextValueSlot: SlotIndex
      if let ident = nextValue as? _AnyIDView {
        nextValueSlot = .id(ident.anyId)
      } else {
        nextValueSlot = .index(partialResult.processedChildCount)
      }

//      print("TreeReducer.reduce()\n ++ nextValue \(nextValue)\n ++ nextExisting \(partialResult.nextExisting)")

      let resultChild: Result
      if let view = nextValue as? any View,
         let existing = partialResult.unclaimedCurrentChildren[nextValueSlot],
         existing.typeInfo?.type == typeInfo(of: T.self)?.type
      {
        partialResult.unclaimedCurrentChildren.removeValue(forKey: nextValueSlot)
        let traits = Renderer.isPrimitive(view) ? .init() : partialResult.nextTraits
        let c = update(existing, &nextValue, nil, traits)
        resultChild = Result(
          fiber: existing,
          currentChildren: existing.mappedChildren,
          visitChildren: visitChildren(partialResult.fiber?.reconciler, nextValue),
          parent: partialResult,
          nextTraits: traits
        )
        resultChild.newContent = c
      } else {
        let elementParent = partialResult.fiber?.element != nil
          ? partialResult.fiber
          : partialResult.fiber?.elementParent
        let preferenceParent = partialResult.fiber?.preferences != nil
          ? partialResult.fiber
          : partialResult.fiber?.preferenceParent
        let fiber = createFiber(
          &nextValue,
          nil,
          partialResult.fiber,
          elementParent,
          preferenceParent,
          nil,
          partialResult.nextTraits,
          partialResult.fiber?.reconciler
        )
        let traits: _ViewTraitStore
        if let view = nextValue as? any View, Renderer.isPrimitive(view) {
          traits = .init()
        } else {
          traits = partialResult.nextTraits
        }

        resultChild = Result(
          fiber: fiber,
          currentChildren: [:],
          visitChildren: visitChildren(partialResult.fiber?.reconciler, nextValue),
          parent: partialResult,
          nextTraits: traits
        )

        resultChild.didInsert = true
      }
//      if let existing = partialResult.nextExisting {
////        existing.updateDynamicProperties()
//        existing.alternate = partialResult.nextExistingAlternate
//        // If a fiber already exists, simply update it with the new view.
//        let elementParent = partialResult.fiber?.element != nil
//          ? partialResult.fiber
//          : partialResult.fiber?.elementParent
//        existing.elementParent = elementParent
//        let key: ObjectIdentifier?
//        if let elementParent = existing.elementParent {
//          key = ObjectIdentifier(elementParent)
//        } else {
//          key = nil
//        }
//        let newContent = update(
//          existing,
//          &nextValue,
//          key.map { partialResult.elementIndices[$0, default: 0] },
//          partialResult.nextTraits
//        )
//
//        if existing.typeInfo?.type != existing.alternate?.typeInfo?.type {
//          existing.appear()
//        }
//
//        var didReplaceElement = false
//
//        if let c = newContent, c != existing.element?.content {
//          partialResult.updates.append((existing, c))
//        }
//        if newContent == nil, let alt = existing.alternate, alt.element != nil {
//          partialResult.deletions.append(alt)
//          existing.alternate = nil
//          didReplaceElement = true
//        }
//        print(" +++ did replace? \(didReplaceElement)")
//
//        resultChild = Result(
//          fiber: existing,
//          visitChildren: visitChildren(partialResult.fiber?.reconciler, nextValue),
//          parent: partialResult,
//          child: didReplaceElement ? nil : existing.child,
//          alternateChild: didReplaceElement ? nil : existing.alternate?.child,
//          newContent: newContent,
//          elementIndices: partialResult.elementIndices,
//          nextTraits: existing.element != nil ? .init() : partialResult.nextTraits
//        )
//        resultChild.did
//        partialResult.nextExisting = partialResult.nextExisting?.sibling
//        partialResult.nextExistingAlternate = partialResult.nextExistingAlternate?.sibling
//        existing.sibling = nil
//        existing.child = nil
//      } else {
//        let elementParent = partialResult.fiber?.element != nil
//          ? partialResult.fiber
//          : partialResult.fiber?.elementParent
//        let preferenceParent = partialResult.fiber?.preferences != nil
//          ? partialResult.fiber
//          : partialResult.fiber?.preferenceParent
//        let key: ObjectIdentifier?
//        if let elementParent = elementParent {
//          key = ObjectIdentifier(elementParent)
//        } else {
//          key = nil
//        }
//        // Otherwise, create a new fiber for this child.
//        let fiber = createFiber(
//          &nextValue,
//          nil,
//          partialResult.fiber,
//          elementParent,
//          preferenceParent,
//          key.map { partialResult.elementIndices[$0, default: 0] },
//          partialResult.nextTraits,
//          partialResult.fiber?.reconciler
//        )
//
//        fiber.appear()
//
//        // If a fiber already exists for an alternate, link them.
//        if let alternate = partialResult.nextExistingAlternate {
//          fiber.alternate = alternate
//          alternate.alternate = fiber
//          partialResult.nextExistingAlternate = alternate.sibling
//
//          if alternate.element != nil { partialResult.deletions.append(alternate) }
//        }
//        resultChild = Result(
//          fiber: fiber,
//          visitChildren: visitChildren(partialResult.fiber?.reconciler, nextValue),
//          parent: partialResult,
//          child: nil,
//          alternateChild: fiber.alternate?.child,
//          elementIndices: partialResult.elementIndices,
//          nextTraits: fiber.element != nil ? .init() : partialResult.nextTraits
//        )
//      }

      partialResult.processedChildCount += 1

      // Get the last child element we've processed, and add the new child as its sibling.
      if let lastSibling = partialResult.lastSibling {
        lastSibling.fiber?.sibling = resultChild.fiber
        lastSibling.sibling = resultChild
      } else {
        // Otherwise setup the first child
        partialResult.fiber?.child = resultChild.fiber
        partialResult.child = resultChild
      }
      partialResult.lastSibling = resultChild
    }
  }
}
