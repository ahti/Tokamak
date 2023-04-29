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
//  Created by Carson Katri on 6/16/22.
//

import Foundation

private extension FiberReconciler.Fiber {
  /// calls `onAppear` action for the represented view and all descendants
  func callAppear() {
    _ = walk(self) {
      if case let .view(action as AppearanceActionType, _) = $0.content {
        action.appear?()
      }
      return true
    }
  }

  /// calls `onDisappear` action for the represented view and all descendants
  func callDisappear() {
    _ = walk(self) {
      if case let .view(action as AppearanceActionType, _) = $0.content {
        action.disappear?()
      }
      return true
    }
  }

  /// returns remove mutations for the first descendants hanving an element
  func deleteElementChildren() -> [Mutation<Renderer>] {
    var results: [Mutation<Renderer>] = []
    _ = walk(self) { child -> WalkWorkResult<()> in
      if let el = child.element {
        results.append(.remove(element: el, parent: child.elementParent!.element!))
        return .stepOver
      } else {
        return .stepIn
      }
    }
    return results
  }
}

/// Walk the current tree, recomputing at each step to check for discrepancies.
///
/// Parent-first depth-first traversal.
/// Take this `View` tree for example.
/// ```swift
/// VStack {
///   HStack {
///     Text("A")
///     Text("B")
///   }
///   Text("C")
/// }
/// ```
/// Basically, we read it like this:
/// 1. `VStack` has children, so we go to it's first child, `HStack`.
/// 2. `HStack` has children, so we go further to it's first child, `Text`.
/// 3. `Text` has no child, but has a sibling, so we go to that.
/// 4. `Text` has no child and no sibling, so we return to the `HStack`.
/// 5. We've already read the children, so we look for a sibling, `Text`.
/// 6. `Text` has no children and no sibling, so we return to the `VStack.`
/// We finish once we've returned to the root element.
/// ```
///    ┌──────┐
///    │VStack│
///    └──┬───┘
///   ▲ 1 │
///   │   └──►┌──────┐
///   │       │HStack│
///   │     ┌─┴───┬──┘
///   │     │   ▲ │ 2
///   │     │   │ │  ┌────┐
///   │     │   │ └─►│Text├─┐
/// 6 │     │ 4 │    └────┘ │
///   │     │   │           │ 3
///   │   5 │   │    ┌────┐ │
///   │     │   └────┤Text│◄┘
///   │     │        └────┘
///   │     │
///   │     └►┌────┐
///   │       │Text│
///   └───────┴────┘
/// ```
struct ReconcilePass: FiberReconcilerPass {
  func run<R>(
    in reconciler: FiberReconciler<R>,
    root: FiberReconciler<R>.TreeReducer.Result,
    changedFibers: Set<ObjectIdentifier>,
    caches: FiberReconciler<R>.Caches
  ) where R: FiberRenderer {
    var node = root

    // Enabled when we reach the `reconcileRoot`.
    var shouldReconcile = false

    while true {
      if !shouldReconcile {
        if let fiber = node.fiber,
           changedFibers.contains(ObjectIdentifier(fiber))
        {
          shouldReconcile = true
        } else if let alternate = node.fiber?.alternate,
                  changedFibers.contains(ObjectIdentifier(alternate))
        {
          shouldReconcile = true
        }
      }
      print("ReconcilePass.run() looping \n -- w/ node \(node.fiber!)\n -- el \(node.fiber?.element)\n -- alternate \(node.fiber!.alternate)\n -- shoudlReconcile \(shouldReconcile)")

      // If this fiber has an element, set its `elementIndex`
      // and increment the `elementIndices` value for its `elementParent`.
      if node.fiber?.element != nil,
         let elementParent = node.fiber?.elementParent
      {
        node.fiber?.elementIndex = caches.elementIndex(for: elementParent, increment: true)
      }

      if let fiber = node.fiber, shouldReconcile || true {
        invalidateCache(for: fiber, in: reconciler, caches: caches)

        if node.didInsert {
          fiber.callAppear()
        }

        if let element = fiber.element,
           let parent = fiber.elementParent?.element,
           let index = fiber.elementIndex,
           node.didInsert
        {
          caches.mutations.append(.insert(element: element, parent: parent, index: index))
        }

        if let element = fiber.element, let c = node.newContent {
          caches.mutations.append(
            .update(
              previous: element,
              newContent: c,
              geometry: fiber.geometry ?? .init(
                origin: .init(origin: .zero),
                dimensions: .init(size: .zero, alignmentGuides: [:]),
                proposal: .unspecified
              )
            )
          )
        }
      }

      // Pass view traits down to the nearest element fiber.
      if let traits = node.fiber?.outputs.traits,
         !traits.values.isEmpty
      {
        node.nextTraits.values.merge(traits.values, uniquingKeysWith: { $1 })
      }

      // Update `DynamicProperty`s before accessing the `View`'s body.
      node.fiber?.updateDynamicProperties()
      // Compute the children of the node.
      let reducer = FiberReconciler<R>.TreeReducer.SceneVisitor(initialResult: node)
      node.visitChildren(reducer)

      let orphans = reducer.result.unclaimedCurrentChildren.values
      for d in orphans {
        d.callDisappear()
        let deletions = d.deleteElementChildren()
        caches.mutations.insert(contentsOf: deletions, at: 0)
      }

      node.fiber?.preferences?.reset()

      if reconciler.renderer.useDynamicLayout,
         let fiber = node.fiber
      {
        if let element = fiber.element,
           let elementParent = fiber.elementParent
        {
          let parentKey = ObjectIdentifier(elementParent)
          let subview = LayoutSubview(
            id: ObjectIdentifier(fiber),
            traits: fiber.outputs.traits,
            fiber: fiber,
            element: element,
            caches: caches
          )
          caches.layoutSubviews[parentKey, default: .init(elementParent)].storage.append(subview)
        }
      }

      // Walk down all the way into the deepest child.
      if let child = reducer.result.child {
        node = child
        continue
      } else if let alternateChild = node.fiber?.alternate?.child {
        // The alternate has a child that no longer exists.
        if let parent = node.fiber?.element != nil ? node.fiber : node.fiber?.elementParent {
          invalidateCache(for: parent, in: reconciler, caches: caches)
        }
        var nextChildOrSibling: FiberReconciler.Fiber? = alternateChild
        while let child = nextChildOrSibling {
          child.callDisappear()
          caches.mutations.insert(contentsOf: child.deleteElementChildren(), at: 0)
          nextChildOrSibling = child.sibling
        }
      }
      if reducer.result.child == nil {
        // Make sure we clear the child if there was none
        node.fiber?.child = nil
      }

      // If we've made it back to the root, then exit.
      if node === root {
        return
      }

      // Now walk back up the tree until we find a sibling.
      while node.sibling == nil {
        if let fiber = node.fiber,
           fiber.element != nil
        {
          propagateCacheInvalidation(for: fiber, in: reconciler, caches: caches)
        }

        if let preferences = node.fiber?.preferences {
          if let action = node.fiber?.outputs.preferenceAction {
            action(preferences)
          }
          if let parentPreferences = node.fiber?.preferenceParent?.preferences {
            parentPreferences.merge(preferences)
          }
        }

        var alternateSibling = node.fiber?.alternate?.sibling
        // The alternate had siblings that no longer exist.
        while let currentAltSibling = alternateSibling {
          if let fiber = currentAltSibling.elementParent {
            invalidateCache(for: fiber, in: reconciler, caches: caches)
          }
          currentAltSibling.callDisappear()
          caches.mutations.insert(contentsOf: currentAltSibling.deleteElementChildren(), at: 0)
          alternateSibling = currentAltSibling.sibling
        }
        guard let parent = node.parent else { return }
        // When we walk back to the root, exit
        guard parent !== root.fiber?.alternate else { return }
        node = parent
      }

      if let fiber = node.fiber {
        propagateCacheInvalidation(for: fiber, in: reconciler, caches: caches)
      }

      // Walk across to the sibling, and repeat.
      node = node.sibling!
    }
  }

  /// Remove cached size values if something changed.
  func invalidateCache<R: FiberRenderer>(
    for fiber: FiberReconciler<R>.Fiber,
    in reconciler: FiberReconciler<R>,
    caches: FiberReconciler<R>.Caches
  ) {
    guard reconciler.renderer.useDynamicLayout else { return }
    caches.updateLayoutCache(for: fiber) { cache in
      cache.markDirty()
    }
    if let alternate = fiber.alternate {
      caches.updateLayoutCache(for: alternate) { cache in
        cache.markDirty()
      }
    }
  }

  @inlinable
  func propagateCacheInvalidation<R: FiberRenderer>(
    for fiber: FiberReconciler<R>.Fiber,
    in reconciler: FiberReconciler<R>,
    caches: FiberReconciler<R>.Caches
  ) {
    guard caches.layoutCache(for: fiber)?.isDirty ?? false,
          let elementParent = fiber.elementParent
    else { return }
    invalidateCache(for: elementParent, in: reconciler, caches: caches)
  }
}

extension FiberReconcilerPass where Self == ReconcilePass {
  static var reconcile: ReconcilePass { ReconcilePass() }
}
