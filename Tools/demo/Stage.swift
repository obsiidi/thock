import AppKit
import Metal
import SceneKit

// The 3D stage: a MacBook-like laptop built from primitives (metres), keys
// that travel and glow when pressed, the live screen as a texture, studio
// light, a glossy floor and a camera that flies along keyframes.

func v3(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)) }
func + (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z) }
func - (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z) }
func * (a: SCNVector3, k: Double) -> SCNVector3 { SCNVector3(a.x * CGFloat(k), a.y * CGFloat(k), a.z * CGFloat(k)) }
func lerp(_ a: SCNVector3, _ b: SCNVector3, _ t: Double) -> SCNVector3 { a + (b - a) * t }
func length(_ a: SCNVector3) -> Double { Double((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()) }

final class Stage {
    let scene = SCNScene()
    let renderer: SCNRenderer
    let cameraNode = SCNNode()
    let camera = SCNCamera()
    let screen: Screen

    final class Key {
        let node: SCNNode, top: SCNMaterial, label: CGImage, lit: CGImage, rest: SCNVector3
        var lit_ = false
        init(node: SCNNode, top: SCNMaterial, label: CGImage, lit: CGImage, rest: SCNVector3) {
            self.node = node; self.top = top; self.label = label; self.lit = lit; self.rest = rest
        }
    }
    var keys: [String: Key] = [:]
    var strokesByKey: [String: [Stroke]] = [:]
    let screenMat = SCNMaterial(), padMat = SCNMaterial()
    var screenNode = SCNNode()
    var lights: [(SCNLight, CGFloat)] = []

    let u = 0.0182            // key pitch
    let env = ProcessInfo.processInfo.environment
    lazy var lightScale = CGFloat(Double(env["LIGHT"] ?? "") ?? 0.04)
    lazy var envScale = CGFloat(Double(env["ENV"] ?? "") ?? 0.2)
    let baseTop = 0.011

    init(screen: Screen) {
        self.screen = screen
        renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        build()
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        for s in strokes { strokesByKey[s.key, default: []].append(s) }
    }

    // MARK: materials

    func pbr(_ r: Double, _ g: Double, _ b: Double, metal: Double, rough: Double) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        m.metalness.contents = NSNumber(value: metal)
        m.roughness.contents = NSNumber(value: rough)
        return m
    }

    /// Key cap faces: label (backlit) and lit (pressed) textures.
    func keyTextures(_ label: String, w: Double, d: Double, small: Bool) -> (CGImage, CGImage) {
        let ph = 192, pw = max(64, Int(Double(ph) * w / d))
        func make(_ lit: Bool) -> CGImage {
            let c = canvas(pw, ph)
            c.setFillColor(gray(0)); c.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
            if lit {
                let g = CGGradient(colorsSpace: srgb, colors: [gray(1, 0.95), gray(0.85, 0.5)] as CFArray, locations: [0, 1])!
                c.drawRadialGradient(g, startCenter: CGPoint(x: pw / 2, y: ph / 2), startRadius: 0,
                                     endCenter: CGPoint(x: pw / 2, y: ph / 2), endRadius: CGFloat(max(pw, ph)) * 0.75, options: [.drawsAfterEndLocation])
            }
            let col = lit ? gray(0.05) : gray(1, 0.95)
            if small {
                text(c, label, uiFont(CGFloat(ph) * 0.2), col, x: 18, y: CGFloat(ph) - 22)
            } else if !label.isEmpty {
                text(c, label, uiFont(CGFloat(ph) * 0.34), col, x: CGFloat(pw) / 2, y: CGFloat(ph) * 0.62, align: .center)
            }
            return c.makeImage()!
        }
        return (make(false), make(true))
    }

    // MARK: build

    func build() {
        scene.background.contents = NSColor.black
        scene.lightingEnvironment.contents = environment()
        scene.lightingEnvironment.intensity = 1.1

        let floor = SCNFloor()
        floor.reflectivity = 0.06
        floor.reflectionFalloffEnd = 0.25
        floor.firstMaterial = pbr(0.004, 0.004, 0.005, metal: 0, rough: 0.5)
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

        let alu = pbr(0.24, 0.25, 0.27, metal: 1, rough: 0.5)
        // key caps: matte black; Blinn keeps grazing-angle Fresnel from greying them out
        func matte() -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = NSColor(white: 0.02, alpha: 1)
            m.specular.contents = NSColor(white: 0.12, alpha: 1)
            m.shininess = 0.25
            return m
        }
        let black = matte()
        let bezel = pbr(0.01, 0.01, 0.012, metal: 0.2, rough: 0.12)

        let base = SCNBox(width: 0.304, height: CGFloat(baseTop), length: 0.215, chamferRadius: 0.004)
        base.materials = [alu]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = v3(0, baseTop / 2, 0)
        scene.rootNode.addChildNode(baseNode)

        // keyboard: function row + five rows, 14.5 units wide
        typealias K = (id: String, label: String, units: Double, small: Bool)
        func k(_ l: String, _ un: Double = 1, id: String? = nil, small: Bool = false) -> K { (id ?? l, l, un, small) }
        let fnRow: [K] = [k("esc", 1.5, small: true)] + (1...12).map { k("F\($0)", 1, small: true) } + [k("", 1, id: "touchid")]
        let rows: [[K]] = [
            ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="].map { k($0) } + [k("delete", 1.5, small: true)],
            [k("tab", 1.5, small: true)] + ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\"].map { k($0) },
            [k("caps lock", 1.75, id: "caps", small: true)] + ["A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'"].map { k($0) }
                + [k("return", 1.75, small: true)],
            [k("shift", 2.25, id: "shiftL", small: true)] + ["Z", "X", "C", "V", "B", "N", "M", ",", ".", "/"].map { k($0) }
                + [k("shift", 2.25, id: "shiftR", small: true)],
            [k("fn", 1, small: true), k("control", 1, small: true), k("option", 1, id: "optionL", small: true),
             k("command", 1.25, id: "commandL", small: true), k("", 5, id: "space"), k("command", 1.25, id: "commandR", small: true),
             k("option", 1, id: "optionR", small: true), k("◀", 1, id: "left"), k("▲▼", 1, id: "updown"), k("▶", 1, id: "right")],
        ]
        let startX = -14.5 * u / 2
        func place(_ row: [K], z: Double, depth: Double) {
            var cum = 0.0
            for key in row {
                let w = key.units * u - 0.0022
                let x = startX + (cum + key.units / 2) * u
                cum += key.units
                let box = SCNBox(width: CGFloat(w), height: 0.003, length: CGFloat(depth), chamferRadius: 0.0011)
                let top = matte()
                let (label, lit) = keyTextures(key.label, w: w, d: depth, small: key.small)
                top.emission.contents = label
                top.emission.intensity = 0.55
                box.materials = [black, black, black, black, top, black]
                let node = SCNNode(geometry: box)
                let rest = v3(x, baseTop - 0.0007, z)
                node.position = rest
                scene.rootNode.addChildNode(node)
                keys[key.id] = Key(node: node, top: top, label: label, lit: lit, rest: rest)
            }
        }
        place(fnRow, z: -0.0905, depth: 0.0095)
        for (i, row) in rows.enumerated() { place(row, z: -0.0754 + Double(i) * u, depth: 0.0162) }

        // trackpad, flush with the deck; its emission shows click ripples
        let pad = SCNBox(width: 0.134, height: 0.0006, length: 0.082, chamferRadius: 0.0003)
        padMat.lightingModel = .physicallyBased
        padMat.diffuse.contents = NSColor(srgbRed: 0.22, green: 0.23, blue: 0.25, alpha: 1)
        padMat.metalness.contents = NSNumber(value: 0.15)
        padMat.roughness.contents = NSNumber(value: 0.55)
        padMat.emission.contents = NSColor.black
        pad.materials = [alu, alu, alu, alu, padMat, alu]
        let padNode = SCNNode(geometry: pad)
        padNode.position = v3(0, baseTop + 0.0001, 0.062)
        scene.rootNode.addChildNode(padNode)

        // lid on a hinge at the back edge, opened 110°; screen on its inner face
        let hinge = SCNNode()
        hinge.position = v3(0, baseTop, -0.1075)
        hinge.eulerAngles.x = CGFloat(-110 * Double.pi / 180)
        scene.rootNode.addChildNode(hinge)
        let lid = SCNBox(width: 0.304, height: 0.0045, length: 0.212, chamferRadius: 0.002)
        lid.materials = [alu, alu, alu, alu, alu, bezel]
        let lidNode = SCNNode(geometry: lid)
        lidNode.position = v3(0, 0.00225, 0.106)
        hinge.addChildNode(lidNode)
        let plane = SCNPlane(width: 0.286, height: 0.186)
        screenMat.lightingModel = .constant
        screenMat.diffuse.contents = NSColor.black
        plane.materials = [screenMat]
        screenNode = SCNNode(geometry: plane)
        screenNode.position = v3(0, -0.00228, 0.006)
        screenNode.eulerAngles.x = CGFloat(Double.pi / 2)
        lidNode.addChildNode(screenNode)

        // lights
        func spot(_ i: CGFloat, _ col: NSColor, at p: SCNVector3, shadow: Bool) {
            let l = SCNLight()
            l.type = .spot
            l.intensity = i
            l.color = col
            l.spotInnerAngle = 18; l.spotOuterAngle = 42
            if shadow {
                l.castsShadow = true; l.shadowRadius = 6; l.shadowSampleCount = 16; l.shadowMapSize = CGSize(width: 4096, height: 4096)
                l.shadowColor = NSColor(white: 0, alpha: 0.75)
            }
            let n = SCNNode(); n.light = l; n.position = p
            n.look(at: v3(0, 0.03, -0.02))
            scene.rootNode.addChildNode(n)
            lights.append((l, i))
        }
        spot(1100, NSColor(srgbRed: 1, green: 0.96, blue: 0.9, alpha: 1), at: v3(-0.55, 0.9, 0.55), shadow: true)
        spot(900, NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1), at: v3(0.7, 0.45, -0.75), shadow: false)
        spot(260, NSColor(white: 1, alpha: 1), at: v3(0.5, 0.35, 0.8), shadow: false)
        let glow = SCNLight()
        glow.type = .omni; glow.intensity = 25; glow.color = NSColor(srgbRed: 0.6, green: 0.7, blue: 1, alpha: 1)
        glow.attenuationStartDistance = 0.05; glow.attenuationEndDistance = 0.45
        let gn = SCNNode(); gn.light = glow; gn.position = v3(0, 0.12, -0.08)
        scene.rootNode.addChildNode(gn)
        lights.append((glow, 25))

        camera.zNear = 0.004; camera.zFar = 30
        camera.fieldOfView = 30
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = CGFloat(Double(ProcessInfo.processInfo.environment["EXPOSURE"] ?? "") ?? 0)
        camera.bloomIntensity = 0.45; camera.bloomThreshold = 1.1; camera.bloomBlurRadius = 12
        camera.vignettingIntensity = 0.45; camera.vignettingPower = 0.9
        camera.wantsDepthOfField = true
        camera.focalBlurSampleCount = 14
        camera.fStop = 4
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
    }

    /// Studio environment for reflections: two soft boxes and a dim horizon.
    func environment() -> CGImage {
        let w = 1024, h = 512
        let c = canvas(w, h)
        c.setFillColor(gray(0)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let band = CGGradient(colorsSpace: srgb, colors: [gray(0.0), gray(0.06), gray(0.0)] as CFArray, locations: [0.35, 0.5, 0.65])!
        c.drawLinearGradient(band, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        for (x, y, r, a) in [(360.0, 120.0, 120.0, 1.0), (820.0, 150.0, 90.0, 0.55), (120.0, 200.0, 70.0, 0.3)] {
            let g = CGGradient(colorsSpace: srgb, colors: [gray(1, a), gray(1, a * 0.6), gray(1, 0)] as CFArray, locations: [0, 0.5, 1])!
            c.saveGState()
            c.translateBy(x: x, y: y); c.scaleBy(x: 1.6, y: 0.7)
            c.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: CGFloat(r), options: [])
            c.restoreGState()
        }
        return c.makeImage()!
    }

    // MARK: geometry helpers

    func screenPoint(_ px: CGPoint) -> SCNVector3 {
        let x = (Double(px.x) / Double(Screen.SW) - 0.5) * 0.286, y = (0.5 - Double(px.y) / Double(Screen.SH)) * 0.186
        return screenNode.convertPosition(v3(x, y, 0), to: nil)
    }
    var screenNormal: SCNVector3 { screenNode.convertVector(v3(0, 0, 1), to: nil) }
    func keyPos(_ id: String) -> SCNVector3 { keys[id]?.rest ?? v3(0, baseTop, -0.04) }

    // MARK: camera path

    enum Ease { case smooth, whip, linear }
    struct Shot { let t: Double; let eye: SCNVector3; let target: SCNVector3; let fov: Double; let fStop: Double; let ease: Ease; let arc: SCNVector3 }
    lazy var shots: [Shot] = {
        let N = screenNormal
        let icon = screenPoint(screen.iconPoint), picker = screenPoint(screen.pickerPoint)
        let pop = screenPoint(CGPoint(x: screen.popRect.midX, y: screen.popRect.minY + 260))
        let fj = (keyPos("F") + keyPos("J")) * 0.5
        let padC = v3(0, baseTop, 0.062)
        func s(_ t: Double, _ eye: SCNVector3, _ target: SCNVector3, fov: Double = 30, f: Double = 4, _ e: Ease = .smooth,
               arc: SCNVector3 = v3(0, 0, 0)) -> Shot {
            Shot(t: t, eye: eye, target: target, fov: fov, fStop: f, ease: e, arc: arc)
        }
        return [
            s(0, v3(-0.95, 0.5, 0.62), v3(0, 0.07, -0.05), f: 5.6),
            s(at(2), v3(-0.62, 0.3, 0.72), v3(0, 0.08, -0.05), f: 5.6, .linear),
            s(at(3) - 0.2, v3(-0.1, 0.19, 0.6), v3(0, 0.1, -0.08), f: 5.6, .smooth),
            // drop: push into the menu bar
            s(at(3, 1.3), icon + N * 0.2 + v3(-0.03, -0.04, 0), icon + v3(0, -0.035, 0), fov: 26, f: 2.8, .whip, arc: v3(0, 0.04, 0)),
            s(at(4, 1), icon + N * 0.19 + v3(-0.05, -0.06, 0), pop + v3(-0.05, 0.02, 0), fov: 26, f: 2.8, .smooth),
            s(at(5) - 0.15, picker + N * 0.2 + v3(-0.02, -0.05, 0), pop + v3(-0.03, 0, 0), fov: 26, f: 2.8, .smooth),
            // swoop down to the keys
            s(at(5, 1.2), v3(0.17, 0.055, 0.14), v3(-0.03, 0.012, -0.045), fov: 32, f: 2.2, .whip, arc: v3(0.05, 0.05, 0.05)),
            s(at(7) - 0.1, v3(-0.15, 0.06, 0.15), v3(0.03, 0.012, -0.045), fov: 32, f: 2.2, .smooth),
            // macro on F and J
            s(at(7, 1), fj + v3(0.04, 0.032, 0.08), fj + v3(0, 0, -0.004), fov: 30, f: 1.8, .whip, arc: v3(0, 0.02, 0)),
            s(at(9) - 0.1, fj + v3(0.018, 0.022, 0.05), fj, fov: 30, f: 1.8, .smooth),
            // up to the popover for the packs
            s(at(9, 1.1), pop + N * 0.24 + v3(-0.04, -0.02, 0), pop + v3(0, -0.01, 0), fov: 28, f: 2.8, .whip, arc: v3(-0.03, 0.05, 0.03)),
            s(at(11) - 0.1, pop + N * 0.22 + v3(0.035, -0.03, 0), pop + v3(0, -0.01, 0), fov: 28, f: 2.8, .smooth),
            // back for line two: screen and keys together
            s(at(11, 1.1), v3(0.03, 0.2, 0.37), v3(0, 0.07, -0.06), fov: 32, f: 4, .whip, arc: v3(0, 0.03, 0.03)),
            s(at(12) - 0.1, v3(0.08, 0.18, 0.32), v3(0, 0.07, -0.06), fov: 32, f: 4, .smooth),
            // trackpad from above
            s(at(12, 1.0), v3(0.08, 0.17, 0.22), padC, fov: 30, f: 2.8, .whip),
            s(at(13) - 0.1, v3(-0.02, 0.15, 0.21), padC, fov: 30, f: 2.8, .smooth),
            // hero: crane out, laptop on the right, wordmark on the left
            s(at(13, 2.2), v3(0.62, 0.32, 0.64), v3(-0.17, 0.09, -0.03), fov: 30, f: 5.6, .smooth, arc: v3(0, 0.12, 0)),
            s(total, v3(0.82, 0.29, 0.3), v3(-0.15, 0.09, -0.03), fov: 30, f: 5.6, .linear),
        ]
    }()

    func cameraPose(_ t: Double) -> (eye: SCNVector3, target: SCNVector3, fov: Double, fStop: Double) {
        let sh = shots
        guard t > sh[0].t else { return (sh[0].eye, sh[0].target, sh[0].fov, sh[0].fStop) }
        let i = (sh.lastIndex { $0.t <= t } ?? 0)
        if i >= sh.count - 1 { let l = sh[sh.count - 1]; return (l.eye, l.target, l.fov, l.fStop) }
        let a = sh[i], b = sh[i + 1]
        let x = (t - a.t) / (b.t - a.t)
        let e: Double
        switch b.ease {
        case .linear: e = x
        case .smooth: e = smoother(x)
        case .whip: e = x < 0.5 ? 16 * pow(x, 5) : 1 - pow(-2 * x + 2, 5) / 2
        }
        let arc = b.arc * sin(Double.pi * e)
        var eye = lerp(a.eye, b.eye, e) + arc
        let target = lerp(a.target, b.target, e)
        // a small jolt on the firm hits of the key-force section
        for h in forceHits where h.force > 0.8 && t >= h.t && t < h.t + 0.3 {
            let k = exp(-(t - h.t) / 0.06) * sin((t - h.t) * 70)
            eye = eye + v3(0, 0.0012 * k, 0)
        }
        return (eye, target, a.fov + (b.fov - a.fov) * e, a.fStop + (b.fStop - a.fStop) * e)
    }

    func applyCamera(_ t: Double) {
        let p = cameraPose(t)
        cameraNode.position = p.eye
        cameraNode.look(at: p.target, up: v3(0, 1, 0), localFront: v3(0, 0, -1))
        camera.fieldOfView = CGFloat(p.fov)
        camera.focusDistance = CGFloat(length(p.target - p.eye))
        camera.fStop = CGFloat(p.fStop)
    }

    // MARK: per frame

    func update(_ t: Double) {
        let fadeIn = CGFloat(smooth(t / 1.8))
        // the key light is dimmed for the trackpad close-up, where it would glare off the deck
        let keyDim = CGFloat(1 - 0.7 * window(t, at(12) - 0.35, at(13) + 0.25, 0.3))
        for (n, (l, i)) in lights.enumerated() { l.intensity = i * fadeIn * lightScale * (n == 0 ? keyDim : 1) }
        scene.lightingEnvironment.intensity = 1.1 * fadeIn * envScale

        screenMat.diffuse.contents = screen.render(t)
        screenMat.diffuse.intensity = 0.25 + 0.75 * fadeIn

        for (id, key) in keys {
            var depth = 0.0, glow = 0.0
            for s in strokesByKey[id] ?? [] where t >= s.t - 0.03 && t < s.t + 1.2 {
                let dt = t - s.t
                let d = dt < 0 ? (dt + 0.03) / 0.03 : 1 - smooth(dt / 0.1)
                depth = max(depth, d * (0.6 + 0.4 * s.force))
                if dt >= 0 { glow = max(glow, (0.35 + 0.65 * s.force) * exp(-dt / 0.3)) }
            }
            key.node.position = key.rest + v3(0, -0.0009 * depth, 0)
            let lit = glow > 0.03
            if lit != key.lit_ { key.top.emission.contents = lit ? key.lit : key.label; key.lit_ = lit }
            key.top.emission.intensity = lit ? CGFloat(0.4 + 2.2 * glow) : 0.55
        }

        // trackpad ripples during the clicks
        if t > at(12) - 0.2 && t < at(13) + 0.5 {
            padMat.emission.contents = trackpadTexture(t)
            padMat.emission.intensity = 2.4
        } else {
            padMat.emission.contents = NSColor.black
        }
        applyCamera(t)
    }

    func trackpadTexture(_ t: Double) -> CGImage {
        let w = 800, h = 490
        let c = canvas(w, h)
        c.setFillColor(gray(0)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let pitch = 20.0
        for y in stride(from: pitch / 2, to: Double(h), by: pitch) { for x in stride(from: pitch / 2, to: Double(w), by: pitch) {
            var b = 0.0
            for k in clicks where t >= k.t && t - k.t < 1.1 {
                let age = t - k.t
                let d = hypot(x - k.u * Double(w), y - k.v * Double(h)), ring = 20 + age * 520
                b = max(b, k.force * exp(-pow((d - ring) / 22, 2)) * (1 - age / 1.1))
                b = max(b, k.force * exp(-d / 26) * exp(-age / 0.25))
            }
            if b > 0.02 { dot(c, CGFloat(x), CGFloat(y), CGFloat(2 + 4 * b), CGFloat(b)) }
        } }
        return c.makeImage()!
    }

    /// One frame, with motion blur from sub-frames when the camera moves fast.
    func frame(_ t: Double) -> CGImage {
        let dt = 1 / Double(FPS)
        let p0 = cameraPose(t), p1 = cameraPose(t + dt)
        let dist = max(0.05, length(p0.target - p0.eye))
        let speed = (length(p1.eye - p0.eye) + length(p1.target - p0.target)) / dist
        let subs = speed > 0.05 ? 5 : speed > 0.02 ? 3 : 1
        update(t)
        if subs == 1 { return snapshot(t) }
        let acc = canvas(W, H)
        for k in 0..<subs {
            let ts = t + dt * 0.5 * Double(k) / Double(subs - 1) - dt * 0.25
            applyCamera(ts)
            let img = snapshot(ts)
            acc.saveGState()
            acc.setAlpha(1 / CGFloat(k + 1))
            acc.translateBy(x: 0, y: CGFloat(H)); acc.scaleBy(x: 1, y: -1)
            acc.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
            acc.restoreGState()
        }
        return acc.makeImage()!
    }

    func snapshot(_ t: Double) -> CGImage {
        let img = renderer.snapshot(atTime: t, with: CGSize(width: W, height: H), antialiasingMode: .multisampling4X)
        var r = CGRect(x: 0, y: 0, width: W, height: H)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    }
}
