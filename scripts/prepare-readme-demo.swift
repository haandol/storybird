import Foundation
import StorybirdCore
let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/readme-demo")
let repository = ProjectRepository(rootURL: base.appendingPathComponent("library"))
try repository.prepare()
let id = UUID()
let movie = try repository.prepareVideoRecordingURL(projectID: id)
try FileManager.default.copyItem(at: base.appendingPathComponent("demo-source.mp4"), to: movie.url)
let clips = [VideoClip(sourceStart: 0, sourceEnd: 6), VideoClip(sourceStart: 6, sourceEnd: 12), VideoClip(sourceStart: 12, sourceEnd: 18)]
var click = TimedPointerClick(time: 1, x: 0.86, y: 0.405, caption: "Start a new project")
click.description.endTime = 5
click.cueSubtitle.text = "Choose Create project to begin your walkthrough."
click.cueSubtitle.endTime = 5
let project = DemoProject(id: id, name: "Northstar · Product walkthrough", summary: "Synthetic tutorial for Storybird documentation", recording: VideoRecordingAsset(filename: movie.filename, duration: 18, width: 1280, height: 720), clips: clips, clicks: [click], subtitles: [TimedSubtitle(startTime: 0, endTime: 5.8, text: "Create your first project in a few clicks.", position: .top), TimedSubtitle(startTime: 6, endTime: 11.8, text: "Record the action and its visible result."), TimedSubtitle(startTime: 12, endTime: 17.8, text: "Add your voice, preview, then export.")])
try repository.saveProjects([project])
print(repository.rootURL.path)
