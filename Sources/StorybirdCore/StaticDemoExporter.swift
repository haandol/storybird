import Foundation

public struct StaticDemoExporter {
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    @discardableResult
    public func export(
        project: DemoProject,
        sourceAssetsDirectory: URL,
        into parentDirectory: URL
    ) throws -> URL {
        let destination = uniqueDestination(
            named: slug(project.name),
            in: parentDirectory
        )
        let assetsDirectory = destination.appendingPathComponent(
            "assets",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: true
        )

        var exportedProject = project
        for index in exportedProject.steps.indices {
            let originalName = exportedProject.steps[index].assetFilename
            let source = sourceAssetsDirectory.appendingPathComponent(originalName)
            let pathExtension = source.pathExtension.isEmpty
                ? "png"
                : source.pathExtension.lowercased()
            let exportedName = "step-\(index + 1).\(pathExtension)"
            let destinationAsset = assetsDirectory.appendingPathComponent(
                exportedName
            )
            try fileManager.copyItem(at: source, to: destinationAsset)
            exportedProject.steps[index].assetFilename = "assets/\(exportedName)"
        }

        let manifestData = try encoder.encode(exportedProject)
        try manifestData.write(
            to: destination.appendingPathComponent("demo.json"),
            options: .atomic
        )

        var embeddedJSON = String(decoding: manifestData, as: UTF8.self)
        embeddedJSON = embeddedJSON.replacingOccurrences(
            of: "</script",
            with: "<\\/script",
            options: .caseInsensitive
        )
        let html = htmlDocument(project: exportedProject, embeddedJSON: embeddedJSON)
        try Data(html.utf8).write(
            to: destination.appendingPathComponent("index.html"),
            options: .atomic
        )

        return destination
    }

    public func slug(_ value: String) -> String {
        let lowercase = value.lowercased()
        let allowed = CharacterSet.alphanumerics
        let pieces = lowercase.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(pieces)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "storybird-demo" : collapsed
    }

    private func uniqueDestination(named name: String, in parent: URL) -> URL {
        let first = parent.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: first.path) else {
            return first
        }

        var suffix = 2
        while true {
            let candidate = parent.appendingPathComponent(
                "\(name)-\(suffix)",
                isDirectory: true
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func htmlDocument(
        project: DemoProject,
        embeddedJSON: String
    ) -> String {
        let accent = cssHex(project.theme.accentHex, fallback: "#5B5CE2")
        let background = cssHex(project.theme.backgroundHex, fallback: "#11131A")
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(htmlEscaped(project.name)) — Storybird</title>
          <style>
            :root { color-scheme: dark; --accent: \(accent); --bg: \(background); }
            * { box-sizing: border-box; }
            html, body { margin: 0; min-height: 100%; background: var(--bg); }
            body {
              min-height: 100vh; display: grid; place-items: center; padding: 28px;
              color: #f7f7fb; font-family: Inter, ui-sans-serif, system-ui, -apple-system,
              BlinkMacSystemFont, "Segoe UI", sans-serif;
            }
            .shell { width: min(1180px, 100%); }
            .topbar {
              display: flex; justify-content: space-between; align-items: end;
              gap: 24px; margin-bottom: 16px;
            }
            .eyebrow {
              color: #a9abc2; font-size: 12px; font-weight: 700;
              letter-spacing: .12em; text-transform: uppercase;
            }
            h1 { margin: 5px 0 0; font-size: clamp(22px, 3vw, 34px); }
            .progress { color: #a9abc2; font-size: 14px; white-space: nowrap; }
            .stage {
              position: relative; overflow: hidden; border-radius: 18px;
              background: #090a0f; border: 1px solid rgba(255,255,255,.12);
              box-shadow: 0 24px 80px rgba(0,0,0,.42);
            }
            .stage img { width: 100%; height: auto; display: block; }
            .text-overlay {
              position: absolute; z-index: 2; padding: 7px 11px; border-radius: 8px;
              color: white; font-size: 13px; font-weight: 650; line-height: 1.35;
              text-align: center; text-shadow: 0 2px 5px rgba(0,0,0,.48);
              box-shadow: 0 4px 12px rgba(0,0,0,.22);
              overflow-wrap: anywhere;
            }
            .subtitle {
              left: 50%; width: max-content; max-width: min(680px, calc(100% - 32px));
              transform: translateX(-50%); font-size: 15px;
            }
            .subtitle.top { top: 16px; }
            .subtitle.bottom { bottom: 16px; }
            .hotspot-caption {
              max-width: min(190px, calc(100% - 16px));
              max-height: calc(100% - 16px); overflow: hidden;
              display: -webkit-box; -webkit-box-orient: vertical;
              -webkit-line-clamp: 3; pointer-events: none;
            }
            .hotspot {
              position: absolute; z-index: 3; width: 34px; height: 34px; border: 0;
              transform: translate(-50%, -50%); border-radius: 50%;
              color: white; background: var(--accent); cursor: pointer;
              box-shadow: 0 0 0 7px color-mix(in srgb, var(--accent) 24%, transparent);
              font-weight: 800; transition: transform .18s ease;
              animation: pulse 2s infinite;
            }
            .hotspot:hover { transform: translate(-50%, -50%) scale(1.12); }
            @keyframes pulse {
              0%, 100% { box-shadow: 0 0 0 7px color-mix(in srgb, var(--accent) 22%, transparent); }
              50% { box-shadow: 0 0 0 13px color-mix(in srgb, var(--accent) 4%, transparent); }
            }
            .callout {
              position: fixed; z-index: 4; width: min(320px, calc(100vw - 32px));
              padding: 16px; border-radius: 14px; color: #20212a; background: white;
              box-shadow: 0 18px 56px rgba(0,0,0,.34);
            }
            .callout strong { display: block; margin-bottom: 5px; }
            .callout p { margin: 0; color: #626477; line-height: 1.45; }
            .callout button {
              margin-top: 13px; border: 0; border-radius: 9px; padding: 8px 12px;
              background: var(--accent); color: white; font-weight: 700; cursor: pointer;
            }
            .footer {
              display: flex; justify-content: flex-end; align-items: center;
              gap: 14px; margin-top: 16px;
            }
            .controls { display: flex; gap: 8px; }
            .controls button {
              border: 1px solid rgba(255,255,255,.16); border-radius: 10px;
              padding: 9px 13px; color: white; background: rgba(255,255,255,.07);
              cursor: pointer;
            }
            .controls button:disabled { opacity: .35; cursor: default; }
            .brand { margin-top: 18px; text-align: center; color: #777a91; font-size: 12px; }
            .empty { padding: 80px 24px; text-align: center; color: #b9bbcc; }
          </style>
        </head>
        <body>
          <main class="shell">
            <div class="topbar">
              <div><div class="eyebrow">Interactive demo</div><h1 id="title"></h1></div>
              <div class="progress" id="progress"></div>
            </div>
            <div class="stage" id="stage"></div>
            <div class="footer">
              <div class="controls">
                <button id="back">Back</button>
                <button id="next">Next</button>
              </div>
            </div>
            \(project.theme.showsBranding ? "<div class=\"brand\">Made with Storybird</div>" : "")
          </main>
          <script id="demo-data" type="application/json">\(embeddedJSON)</script>
          <script>
            const demo = JSON.parse(document.getElementById("demo-data").textContent);
            const stage = document.getElementById("stage");
            const title = document.getElementById("title");
            const progress = document.getElementById("progress");
            const back = document.getElementById("back");
            const next = document.getElementById("next");
            let index = 0;
            let callout = null;
            let completed = false;

            function targetIndex(hotspot) {
              if (!hotspot.targetStepID) {
                return index < demo.steps.length - 1 ? index + 1 : null;
              }
              const found = demo.steps.findIndex(step => step.id === hotspot.targetStepID);
              return found < 0 ? index : found;
            }

            function closeCallout() {
              if (callout) callout.remove();
              callout = null;
            }

            function overlayBackground(style) {
              const hex = /^#[0-9a-f]{6}$/i.test(style.backgroundHex)
                ? style.backgroundHex
                : "#11131A";
              const opacity = Number(style.backgroundOpacity);
              const value = Number.parseInt(hex.slice(1), 16);
              return `rgba(${(value >> 16) & 255}, ${(value >> 8) & 255}, ${value & 255}, ${opacity})`;
            }

            function appendSubtitle(step) {
              if (!step.caption || !step.caption.trim()) return;
              const subtitle = document.createElement("div");
              subtitle.className = `text-overlay subtitle ${step.subtitlePosition === "top" ? "top" : "bottom"}`;
              subtitle.textContent = step.caption;
              subtitle.style.background = overlayBackground(step.subtitleStyle);
              stage.appendChild(subtitle);
            }

            function positionHotspotCaption(caption, hotspot) {
              const inset = 8;
              const pointX = hotspot.x * stage.clientWidth;
              const pointY = hotspot.y * stage.clientHeight;
              const gap = Math.min(30, stage.clientWidth * .08);
              caption.style.maxWidth = `${Math.min(
                190,
                Math.max(stage.clientWidth - inset * 2, 0)
              )}px`;
              caption.style.maxHeight = `${Math.max(stage.clientHeight - inset * 2, 0)}px`;
              caption.style.left = "0";
              caption.style.top = "0";
              caption.style.transform = "none";

              const rect = caption.getBoundingClientRect();
              const desiredLeft = hotspot.x <= .5
                ? pointX + gap
                : pointX - gap - rect.width;
              const maximumLeft = Math.max(
                stage.clientWidth - rect.width - inset,
                inset
              );
              const left = Math.min(
                Math.max(desiredLeft, inset),
                maximumLeft
              );
              const maximumTop = Math.max(
                stage.clientHeight - rect.height - inset,
                inset
              );
              const top = Math.min(
                Math.max(pointY - rect.height / 2, inset),
                maximumTop
              );
              caption.style.left = `${left}px`;
              caption.style.top = `${top}px`;
            }

            function appendHotspotCaption(hotspot) {
              if (!hotspot.caption || !hotspot.caption.trim()) return;
              const caption = document.createElement("div");
              caption.className = "text-overlay hotspot-caption";
              caption.textContent = hotspot.caption;
              caption.setAttribute("aria-hidden", "true");
              caption.style.background = overlayBackground(hotspot.captionStyle);
              stage.appendChild(caption);
              positionHotspotCaption(caption, hotspot);
            }

            function complete() {
              completed = true;
              closeCallout();
              progress.textContent = "Complete";
              next.disabled = true;
            }

            function follow(hotspot) {
              const target = targetIndex(hotspot);
              if (target === null) {
                complete();
                return;
              }
              index = target;
              render();
            }

            function activate(hotspot, button) {
              closeCallout();
              if (hotspot.kind === "information") {
                callout = document.createElement("div");
                callout.className = "callout";
                const heading = document.createElement("strong");
                heading.textContent = hotspot.title || "Learn more";
                const body = document.createElement("p");
                body.textContent = hotspot.body || "";
                const action = document.createElement("button");
                action.textContent = "Continue";
                action.onclick = () => follow(hotspot);
                callout.append(heading, body, action);
                document.body.appendChild(callout);
                const rect = button.getBoundingClientRect();
                callout.style.left = `${Math.min(rect.left, innerWidth - 336)}px`;
                callout.style.top = `${Math.min(rect.bottom + 12, innerHeight - callout.offsetHeight - 16)}px`;
                return;
              }
              follow(hotspot);
            }

            function render() {
              closeCallout();
              completed = false;
              stage.replaceChildren();
              if (!demo.steps.length) {
                const empty = document.createElement("div");
                empty.className = "empty";
                empty.textContent = "This demo has no screens yet.";
                stage.appendChild(empty);
                title.textContent = demo.name;
                progress.textContent = "0 / 0";
                back.disabled = next.disabled = true;
                return;
              }
              const step = demo.steps[index];
              title.textContent = step.title;
              progress.textContent = `${index + 1} / ${demo.steps.length}`;
              const image = document.createElement("img");
              image.src = step.assetFilename;
              image.alt = step.title;
              stage.appendChild(image);
              const appendOverlays = () => {
                appendSubtitle(step);
                step.hotspots.forEach((hotspot, hotspotIndex) => {
                  appendHotspotCaption(hotspot);
                  const button = document.createElement("button");
                  button.className = "hotspot";
                  button.style.left = `${hotspot.x * 100}%`;
                  button.style.top = `${hotspot.y * 100}%`;
                  button.textContent = hotspot.kind === "information" ? "i" : hotspotIndex + 1;
                  button.setAttribute(
                    "aria-label",
                    hotspot.caption || hotspot.title || "Demo hotspot"
                  );
                  button.onclick = () => activate(hotspot, button);
                  stage.appendChild(button);
                });
              };
              if (image.complete && image.naturalWidth > 0) {
                appendOverlays();
              } else {
                image.addEventListener("load", appendOverlays, { once: true });
              }
              back.disabled = index === 0;
              next.disabled = index === demo.steps.length - 1;
            }

            back.onclick = () => { if (index > 0) { index -= 1; render(); } };
            next.onclick = () => { if (index < demo.steps.length - 1) { index += 1; render(); } };
            window.addEventListener("resize", () => {
              closeCallout();
              if (!completed) render();
            });
            render();
          </script>
        </body>
        </html>
        """
    }

    private func cssHex(_ value: String, fallback: String) -> String {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let isValid = value.count == 7
            && value.first == "#"
            && value.dropFirst().unicodeScalars.allSatisfy(hexadecimal.contains)
        return isValid ? value : fallback
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
