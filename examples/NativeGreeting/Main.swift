import Foundation

@main
struct NativeGreetingMain {
    static func main() {
        MacHelperNative.run(commands: [
            "greet": { input in
                let prefix = input.settings["prefix"] as? String ?? "Hello"
                try input.reportProgress(text: "Preparing native greeting…", title: "Native Greeting")
                return ["text": prefix + ": " + input.text, "title": "Native Greeting"]
            }
        ])
    }
}
