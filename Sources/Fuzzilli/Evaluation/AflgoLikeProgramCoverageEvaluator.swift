import Foundation



struct AflgoLikeFuzzingContext {
    // The number of edges discovered so far
    var num_edges: UInt32 = 0

    var edges: Set<UInt64> = []
    
    // If a basic block is reachable to the target, the entry is the float value of the distance
    var distmap: [UInt64: Double] = [:]
}

class AflgoLikeProgramOutcome : ProgramAspects {
    let hits: [UInt64]

    init(hits: [UInt64]) {
        self.hits = hits
        super.init(outcome: .succeeded)
    }

    public func distance(by distmap: [UInt64: Double]) -> Double {
        return hits.compactMap { distmap[$0] }.reduce(0.0, +) / Double(hits.count)
    }
}


public class AflgoLikeProgramCoverageEvaluator: ComponentBase, ProgramEvaluator {
    private var context = AflgoLikeFuzzingContext()

    public init(runner: ScriptRunner, distmapFile: String) {
        super.init(name: "AflgoLikeProgramCoverageEvaluator")

        // read and parse the distmap file
        // for each line, the first is the basic block address and the second is the distance
        // and each is separated by a space
        let distmap = try! String(contentsOfFile: distmapFile).split(separator: "\n")
        for line in distmap {
            let parts = line.split(separator: " ")
            let bb = UInt64(parts[0], radix: 16)!
            let distance = Double(parts[1])!
            context.distmap[bb] = distance
        }
    }

    public func evaluate(_ execution: Execution) -> ProgramAspects? {
        assert(execution.outcome == .succeeded)

        // read COV_PATH from the environment
        let covFilePath = ProcessInfo.processInfo.environment["COV_PATH"]!
        // read 'cov.cov' file which contains the coverage information
        // each line is a hex number representing a basic block hit
        let covFile = covFilePath + "/cov.cov"
        guard let covData = try? Data(contentsOf: URL(fileURLWithPath: covFile)) else {
            return nil
        }
        let covLines = covData.split(separator: 0x0A)

        // convert the hex numbers to UInt64
        let hits = covLines.map { UInt64(strtoul(String(decoding: $0, as: UTF8.self), nil, 16)) }

        let outcome = AflgoLikeProgramOutcome(hits: hits)
        return outcome
    }

    public func evaluateCrash(_ execution: Execution) -> ProgramAspects? {
        assert(execution.outcome.isCrash())
        // we are not interested in crashes
        return nil
    }

    // used to minimize a program using the execution outcome
    public func hasAspects(_ execution: Execution, _ aspects: ProgramAspects) -> Bool {
        return false // do not minimize
    }

    public var currentScore: Double {
        return Double(context.num_edges) / Double(context.distmap.count)
    }

    public func exportState() -> Data {
        return Data()
    }

    public func importState(_ state: Data) throws {
        
    }

    public func resetState() {
        
    }

    public func computeAspectIntersection(of program: Program, with aspects: ProgramAspects) -> ProgramAspects? {
        let execution = fuzzer.execute(program, purpose: .checkForDeterministicBehavior)
        guard execution.outcome == .succeeded else { return nil }
        guard let secondOutcome = evaluate(execution) as? AflgoLikeProgramOutcome else { return nil }

        let firstHits: Set<UInt64> = Set((aspects as! AflgoLikeProgramOutcome).hits)
        let secondHits: Set<UInt64> = Set(secondOutcome.hits)

        let intersectedHits = secondHits.intersection(firstHits)
        guard intersectedHits.count > 0 else { return nil }
        return AflgoLikeProgramOutcome(hits: Array(intersectedHits))
    }
}