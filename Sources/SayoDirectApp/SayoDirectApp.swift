import SayoAppRuntime
import SayoUpdates

@main enum SayoDirectApp {
    @MainActor static func main() {
        SayoRuntime.run(updater: SparkleAppUpdater())
    }
}
