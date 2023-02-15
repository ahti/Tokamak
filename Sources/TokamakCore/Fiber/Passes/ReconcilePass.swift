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

extension FiberReconciler.Fiber {
  private var anyView: Any {
    switch content {
    case let .app(a, visit: _): return a
    case let .scene(s, visit: _): return s
    case let .view(v, visit: _): return v
    case .none: fatalError()
    }
  }

  func appear() {
    if let appearanceAction = anyView as? AppearanceActionType {
      appearanceAction.appear?()
    }
  }

  func disappear() {
    if let appearanceAction = anyView as? AppearanceActionType {
      appearanceAction.disappear?()
    }
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

    func callDisappear(_ fiber: FiberReconciler<R>.Fiber) {
      _ = walk(fiber) {
        $0.disappear()
        return true
      }
    }

    func deleteElementChildren(_ fiber: FiberReconciler<R>.Fiber) -> [Mutation<R>] {
      var elementChildren: [FiberReconciler<R>.Fiber] = []
      _ = walk(fiber) { child -> WalkWorkResult<()> in
        if child.element != nil {
          elementChildren.append(child)
          return .stepOver
        } else {
          return .stepIn
        }
      }
      return elementChildren.map {
        Mutation<R>.remove(element: $0.element!, parent: $0.elementParent!.element!)
      }
    }

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

      // insertions handeled here, rather than in TreeReducer, because
      // we need to have walked into previous siblings to find nested
      // primitives and update the cached element index
      if let fiber = node.fiber, shouldReconcile || true {
        invalidateCache(for: fiber, in: reconciler, caches: caches)

        if let element = fiber.element,
           let parent = fiber.elementParent?.element,
           let index = fiber.elementIndex,
           fiber.alternate?.element == nil
        {
          caches.mutations.append(.insert(element: element, parent: parent, index: index))
        }
      }

      // Ensure the `TreeReducer` can access any necessary state.
      node.elementIndices = caches.elementIndices
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

      for (fiber, newContent) in reducer.result.updates {
        caches.mutations.append(
          .update(
            previous: fiber.element!,
            newContent: newContent,
            geometry: fiber.geometry ?? .init(
              origin: .init(origin: .zero),
              dimensions: .init(size: .zero, alignmentGuides: [:]),
              proposal: .unspecified
            )
          )
        )
      }

      for d in reducer.result.deletions {
        callDisappear(d)
      }
      let deletions = reducer.result.deletions.lazy.reversed().flatMap {
        deleteElementChildren($0)
      }
      caches.mutations.insert(contentsOf: deletions, at: 0)

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

      // Setup the alternate if it doesn't exist yet.
//      if node.fiber?.alternate == nil {
//        _ = node.fiber?.createAndBindAlternate?()
//      }

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
          callDisappear(child)
          caches.mutations.insert(contentsOf: deleteElementChildren(child), at: 0)
          nextChildOrSibling = child.sibling
        }
      }
      if reducer.result.child == nil {
        // Make sure we clear the child if there was none
        node.fiber?.child = nil
//        node.fiber?.alternate?.child = nil
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
          callDisappear(currentAltSibling)
          caches.mutations.insert(contentsOf: deleteElementChildren(currentAltSibling), at: 0)
          alternateSibling = currentAltSibling.sibling
        }
//        node.fiber?.alternate?.sibling = nil
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

  /// Compare `node` with its alternate, and add any mutations to the list.
//  func reconcile<R: FiberRenderer>(
//    _ node: FiberReconciler<R>.TreeReducer.Result,
//    in reconciler: FiberReconciler<R>,
//    caches: FiberReconciler<R>.Caches
//  ) {
//    guard let fiber = node.fiber else { return }
//
//    if fiber.alternate == nil {
//      fiber.appear()
//    }
//
//    func canUpdate(_ fiber: FiberReconciler<R>.Fiber) -> Bool {
//      fiber.typeInfo?.type == fiber.alternate?.typeInfo?.type
//    }
//
//
//    print("reconcile(...) with \n  el \(fiber.element)\n \n  ae \(fiber.alternate?.element)\n  cu \(canUpdate(fiber))")
//
//    switch (fiber.element, node.newContent, fiber.alternate?.element) {
////    case let (nil, content?, nil):
////      guard let index = fiber.elementIndex, let parent = fiber.elementParent?.element else { break }
////
////      let el = R.ElementType(from: content)
////      fiber.element = el
//////      fiber.alternate?.element = el
////
////      caches.mutations.append(.insert(element: el, parent: parent, index: index))
//
//    case let (el?, maybeContent, altElement?) where !canUpdate(fiber) || fiber.elementParent?.element !== fiber.alternate?.elementParent?.element:
//      guard let parent = fiber.elementParent?.element else { break }
//
////      let el = R.ElementType(from: content)
////      fiber.element = el
////      fiber.alternate?.element = el
//
//      caches.mutations.insert(.remove(element: altElement, parent: fiber.alternate?.elementParent?.element!), at: 0)
//      caches.mutations.append(.insert(element: el, parent: parent, index: fiber.elementIndex!))
//      if let c = maybeContent {
//        caches.mutations.append(.update(previous: el, newContent: c, geometry: fiber.geometry ?? .init(
//          origin: .init(origin: .zero),
//          dimensions: .init(size: .zero, alignmentGuides: [:]),
//          proposal: .unspecified
//        )))
//      }
//
////    case let (nil, content?, element?) where canUpdate(fiber) && content != element.content,
////    case let (element?, content?, alt) where canUpdate(fiber) && content != element.content && fiber.elementParent?.element !== fiber.alternate?.elementParent?.element:
//
//    case let (element?, content?, _) where canUpdate(fiber) && content != element.content:
//      guard fiber.elementParent?.element != nil else { break } // todo: is this needed?
//
////      fiber.element = element
//      caches.mutations.append(.update(
//        previous: element,
//        newContent: content,
//        geometry: fiber.geometry ?? .init(
//          origin: .init(origin: .zero),
//          dimensions: .init(size: .zero, alignmentGuides: [:]),
//          proposal: .unspecified
//        )
//      ))
//
//    case let (nil, nil, alt?):
////    case let (_, nil, alt?):
//      guard let parent = fiber.alternate?.elementParent?.element else { break } // todo: name => altParent?
//      caches.mutations.insert(.remove(element: alt, parent: parent), at: 0)
//
//    case let (element?, nil, nil):
//      guard let parent = fiber.elementParent?.element,
//            let index = fiber.elementIndex
//        else { break }
//
////      if let c = content { element.update(with: c) }
//      caches.mutations.append(.insert(element: element, parent: parent, index: index))
//
//    case let (element?, content, previous?) where !canUpdate(fiber):
//      guard let parent = fiber.elementParent?.element else { break }
//
////      var element = element
////      if let c = content {
////        element = R.ElementType(from: c)
////        fiber.element = element
////      }
//
//      caches.mutations.append(.replace(parent: parent, previous: previous, replacement: element))
//
//    default:
//      break
//    }
//  }

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
