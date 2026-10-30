import Foundation
import CoreMIDI

@main enum LiveMidiMain {
    struct Command: Decodable {
        enum Kind: String, Decodable { case status, stop, set }
        let kind: Kind
        let routes: [UmpLiveRoute]?
        let active: [String]?
        let reserved: [UmpLiveClaim]?
    }
    static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "reservations" {
                guard args.count == 5, args[1] == "--file", args[3] == "--format" else { throw MidiFailure("usage: music-midi-live reservations --file PLAN --format FORMAT") }
                let claims = try liveMidiReservations(Data(contentsOf: URL(fileURLWithPath: args[2])), format: args[4])
                try emit(["kind": "reservations", "schemaVersion": 1, "format": args[4],
                          "reserved": claims.map { claim -> [String: Any] in
                              var value: [String: Any] = ["destination": claim.destination, "scope": claim.scope.json]
                              if let wire = claim.nativeProtocol { value["nativeProtocol"] = wire }
                              return value
                          }])
                return
            }
            guard args.count == 2, args[0] == "--plan" else { throw MidiFailure("usage: music-midi-live --plan LIVE_MIDI_JSON") }
            let plan = try JSONDecoder().decode(UmpLivePlan.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            let owner = try UmpLiveInput(plan: plan)
            owner.onEvent = emit
            owner.onClosed = { error in
                do {
                    if let error { try emit(["kind": "error", "message": String(describing: error)]) }
                    var result = owner.snapshot("stopped"); result["success"] = error == nil
                    try emit(result)
                } catch { diagnostic(error); exit(1) }
                exit(error == nil ? 0 : 1)
            }
            var signals: [DispatchSourceSignal] = []
            for sig in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { owner.stop() }; source.resume(); signals.append(source)
            }
            do { try owner.start() } catch { owner.stop(error: error) }
            DispatchQueue.global().async {
                while let line = readLine() {
                    DispatchQueue.main.async {
                        do {
                            let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
                            switch command.kind {
                            case .stop: owner.stop()
                            case .status:
                                guard owner.state == .running else { return }
                                try emit(owner.snapshot("monitoring"))
                            case .set:
                                guard owner.state == .running else { return }
                                try owner.set(routes: command.routes ?? [], active: command.active ?? [], reserved: command.reserved)
                            }
                        } catch { owner.stop(error: error) }
                    }
                }
                DispatchQueue.main.async { owner.stop() }
            }
            withExtendedLifetime((owner, signals)) { RunLoop.main.run() }
        } catch {
            try? emit(["kind": "error", "message": String(describing: error)]); exit(1)
        }
    }
}
