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
//  Created by Lukas Stabe on 10/30/22.
//

import XCTest

@_spi(TokamakCore) @testable import TokamakCore
import TokamakTestRenderer

final class VaryingPrimitivenessTests: XCTestCase {
  func testVaryingPrimitiveness() {
    enum State {
      case a
      case b([String])
      case c(String, [Int])
      case d(String, [Int], String)
    }

    final class StateManager: ObservableObject {
      private init() { }
      static let shared = StateManager()

      @Published var state = State.a //b(["eins", "2", "III"])
    }

    struct ContentView: View {
      @ObservedObject var sm = StateManager.shared

      var body: some View {
        switch sm.state {
        case .a:
          Button("go to b") {
            sm.state = .b(["eins", "zwei", "drei"])
          }.identified(by: "a.1")
        case .b(let arr):
          VStack {
            Text("b:")
            ForEach(arr, id: \.self) { s in
              Button(s) {
                sm.state = .c(s, s == "zwei" ? [1, 2] : [1])
              }.identified(by: "b.\(s)")
            }
          }
        case .c(let str, let ints):
          VStack {
            Text("c \(str)")
              .font(.headline)
            Text("hello there")
            ForEach(ints, id: \.self) { i in
              let d = "i = \(i)"
              Button(d) {
                sm.state = .d(str, ints, d)
              }.identified(by: "c." + d)
            }
          }
        case .d(_, let ints, let other):
          VStack {
            Text("d \(other)")
            Text("count \(ints.count)")
            Button("back") {
              sm.state = .a
            }.identified(by: "d.back")
          }
        }
      }
    }

    let reconciler = TestFiberRenderer(.root, size: .zero).render(ContentView())
    let root = reconciler.renderer.rootElement

    XCTAssertEqual(root.children.count, 1) // button style
    XCTAssertEqual(root.children[0].children.count, 1) // text

    reconciler.findView(id: "a.1", as: Button<Text>.self).tap()

    XCTAssertEqual(root.children.count, 1)
    XCTAssert(root.children[0].description.contains("VStack"))
    XCTAssertEqual(root.children[0].children.count, 4) // stack content
    XCTAssert(root.children[0].children[0].description.contains("Text"))
    XCTAssert(root.children[0].children[1].description.contains("ButtonStyle"))

    reconciler.findView(id: "b.zwei", as: Button<Text>.self).tap()

    XCTAssertEqual(root.children.count, 1)
    XCTAssert(root.children[0].description.contains("VStack"))
    XCTAssertEqual(root.children[0].children.count, 4) // stack content
    XCTAssert(root.children[0].children[0].description.contains("Text"))
    XCTAssert(root.children[0].children[1].description.contains("Text"))
    XCTAssert(root.children[0].children[2].description.contains("ButtonStyle"))

    reconciler.findView(id: "c.i = 2", as: Button<Text>.self).tap()

    XCTAssertEqual(root.children[0].children.count, 3) // stack content

    reconciler.findView(id: "d.back", as: Button<Text>.self).tap()

    XCTAssertEqual(root.children.count, 1)
    XCTAssert(root.children[0].description.contains("ButtonStyle"))
    XCTAssertEqual(root.children[0].children.count, 1)
    XCTAssert(root.children[0].children[0].description.contains("Text"))

    reconciler.findView(id: "a.1", as: Button<Text>.self).tap()

    XCTAssertEqual(root.children.count, 1)
    XCTAssert(root.children[0].description.contains("VStack"))
    XCTAssertEqual(root.children[0].children.count, 4) // stack content
    XCTAssert(root.children[0].children[0].description.contains("Text"))
    XCTAssert(root.children[0].children[1].description.contains("ButtonStyle"))

    reconciler.findView(id: "b.zwei", as: Button<Text>.self).tap()

    XCTAssertEqual(root.children.count, 1)
    XCTAssert(root.children[0].description.contains("VStack"))
    XCTAssertEqual(root.children[0].children.count, 4) // stack content
    XCTAssert(root.children[0].children[0].description.contains("Text"))
    XCTAssert(root.children[0].children[1].description.contains("Text"))
    XCTAssert(root.children[0].children[2].description.contains("ButtonStyle"))
  }

  func testCorrectParent() {
    final class Router<R>: ObservableObject where R: RawRepresentable, R.RawValue == String {
      private static func currentRoute() -> R {
        return R(rawValue: "")!
      }

      @Published var route: R = Router.currentRoute()
    }

    enum Routes: RawRepresentable {
      init?(rawValue: String) {
        if rawValue == "" { self = .list; return }
        let comps = rawValue.components(separatedBy: "/")
        if comps.count == 1 { self = .package(comps[0]); return }
        if comps.count == 2 { self = .project(comps[0], comps[1]); return }
        return nil
      }

      var rawValue: String {
        switch self {
        case .list: return ""
        case .package(let id): return id
        case .project(let package, let proj): return "\(package)/\(proj)"
        }
      }

      case list
      case package(String)
      case project(String, String)
    }

    struct IdString: Identifiable, ExpressibleByStringLiteral {
      let s: String

      init(stringLiteral value: StringLiteralType) {
        s = value
      }

      var id: String { s }
    }

    struct ListView: View {
      let router: Router<Routes>

      var body: some View {
        VStack {
          Text("packages:")
          let content: [IdString] = ["a", "b", "c"]
          ForEach(content) { p in
            Button(p.s) {
              router.route = .package(p.s)
            }.identified(by: p.s)
          }
        }
      }
    }

    struct PackageView: View {
      let router: Router<Routes>
      let packageId: String

      var body: some View {
        VStack {
          let content: [IdString] = ["1", "2"]
          Text(packageId)
            .font(.headline)
          Text(packageId)
          ForEach(content) { p in
            Button(p.s) {
              router.route = .project(packageId, p.s)
            }.identified(by: p.s)
          }
        }
      }
    }

    struct ContentView: View {
      @ObservedObject var r = Router<Routes>()

      var body: some View {
        switch r.route {
        case .list: ListView(router: r)
        case .package(let package): VStack { PackageView(router: r, packageId: package) }
        case .project(_, let project): VStack { Text("\(project)") }
        }
      }
    }

    let reconciler = TestFiberRenderer(.root, size: .zero).render(ContentView())
    let root = reconciler.renderer.rootElement

    reconciler.findView(id: "a").tap()
    reconciler.findView(id: "1").tap()
    XCTAssert(root.children.count == 1)
  }
}
