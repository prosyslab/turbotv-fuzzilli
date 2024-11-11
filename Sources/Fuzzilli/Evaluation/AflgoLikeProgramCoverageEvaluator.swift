import Foundation

class AflgoLikeProgramOutcome: ProgramAspects {
    let edges: Set<Edge>
    let distance: Double
    let covers: Bool
    let interesting: Bool

    init(edges: Set<Edge>, distance: Double, covers: Bool, interesting: Bool) {
        self.edges = edges
        self.distance = distance
        self.covers = covers
        self.interesting = interesting
        super.init(outcome: .succeeded)
    }
}

struct Edge: Hashable {
    let src: UInt64
    let dst: UInt64
}

public class AflgoLikeProgramCoverageEvaluator: ComponentBase, ProgramEvaluator {
    private var edges: Set<Edge> = []
    private let distmap: [UInt64: Double]

    public init(runner: ScriptRunner, distmapFile: String) {
        // read and parse the distmap file
        // for each line, the first is the basic block address and the second is the distance
        // and each is separated by a space
        let lines = try! String(contentsOfFile: distmapFile).split(separator: "\n")
        var distances: [UInt64: Double] = [:]
        for line in lines {
            let parts = line.split(separator: " ")
            let bb = UInt64(parts[0].dropFirst(2), radix: 16)!
            let distance = Double(parts[1])!
            distances[bb] = distance
        }
        self.distmap = distances

        super.init(name: "AflgoLikeProgramCoverageEvaluator")

        for (block, distance) in self.distmap {
            logger.verbose("Block: \(String(format: "%#llx", block)), Distance: \(distance)")
        }
    }

    public func evaluate(_ execution: Execution) -> ProgramAspects? {
        assert(execution.outcome == .succeeded)
        // assert execution is ScriptExecution
        assert(execution is ScriptExecution)
        let covData = (execution as! ScriptExecution).covout
        let covLines = covData.split(separator: "\n")

        logger.verbose("\(covLines.count) lines of coverage data")
        // print(covLines)
        let blockHits =
            covLines
            .map {
                UInt64($0.dropFirst(2), radix: 16)!
            }  // drop 0x prefix
            .filter { distmap[$0] != nil }  // filter out blocks not in distmap
        // print(blockHits)
        // if there is a hit of distance 0, we have reached the target
        let covers = blockHits.contains(where: { distmap[$0] == 0 })
        if covers {
            logger.verbose("Covering input found")
        }

        let edges = zip(blockHits, blockHits.dropFirst()).map { Edge(src: $0, dst: $1) }

        // check if a new edge is found
        let newEdges = Set(edges).subtracting(self.edges)
        self.edges.formUnion(newEdges)

        let uniqueHits = Set(blockHits)
        let allWeights = uniqueHits.compactMap { distmap[$0] }
        var distance = 65535.0
        if !allWeights.isEmpty {
            distance = allWeights.reduce(0.0, +) / Double(allWeights.count)
        }

        let outcome = AflgoLikeProgramOutcome(
            edges: Set(edges), distance: distance, covers: covers, interesting: !newEdges.isEmpty)
        logger.verbose(
            "Evaluated \(covers ? "Covering" : "Non-covering") program of \(newEdges.count) new edges with distance \(distance)"
        )

        return outcome
    }

    public func dispatchEvent<T>(_ event: Event<T>, data: T) {
        // dispatchPrecondition(condition: .onQueue(queue))
        for listener in event.listeners {
            listener(data)
        }
    }

    public func evaluateCrash(_ execution: Execution) -> ProgramAspects? {
        assert(execution.outcome.isCrash())
        // we are not interested in crashes
        return nil
    }

    // used to minimize a program using the execution outcome
    public func hasAspects(_ execution: Execution, _ aspects: ProgramAspects) -> Bool {
        return false  // do not minimize
    }

    public var currentScore: Double {
        return Double(self.edges.count) / Double(self.distmap.count)
    }

    public func exportState() -> Data {
        return Data()
    }

    public func importState(_ state: Data) throws {

    }

    public func resetState() {

    }

    // Used to determine if re-running results in the same outcome
    // No use for our purposes
    public func computeAspectIntersection(of program: Program, with aspects: ProgramAspects)
        -> ProgramAspects?
    {
        return aspects
        // let execution = fuzzer.execute(program, purpose: .checkForDeterministicBehavior)
        // guard execution.outcome == .succeeded else { return nil }
        // guard let secondOutcome = evaluate(execution) as? AflgoLikeProgramOutcome else {
        //     return nil
        // }

        // let firstHits: Set<UInt64> = Set((aspects as! AflgoLikeProgramOutcome).hits)
        // let secondHits: Set<UInt64> = Set(secondOutcome.hits)

        // let intersectedHits = secondHits.intersection(firstHits)
        // guard intersectedHits.count > 0 else { return nil }
        // return AflgoLikeProgramOutcome(hits: Array(intersectedHits))
    }
}
