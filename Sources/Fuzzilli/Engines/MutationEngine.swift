// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// The core fuzzer responsible for generating and executing programs.
public class MutationEngine: FuzzEngine {
    // The number of consecutive mutations to apply to a sample.
    private let numConsecutiveMutations: Int

    public init(numConsecutiveMutations: Int) {
        self.numConsecutiveMutations = numConsecutiveMutations
        super.init(name: "MutationEngine")
    }

    private func getImportants(parent: Program, child: Program) -> [Instruction] {
        var newInstructions = [Instruction]()
        var importants = [Instruction]()
        for instr in child.code {
            var res = false
            for pInstr in parent.code {
                if instr == pInstr {
                    res = true
                }
            }
            if !res {
                newInstructions.append(instr)
                importants.append(instr)
            }

        }
        for instr in newInstructions {
            if instr.hasOneOutput {
                let outvar = instr.output
                for cInstr in child.code {
                    for input in cInstr.inputs {
                        if outvar == input {
                            importants.append(cInstr)
                            break
                        }
                    }
                }
            }
        }
        return importants
    }

    /// Perform one round of fuzzing.
    ///
    /// High-level fuzzing algorithm:
    ///
    ///     let parent = pickSampleFromCorpus()
    ///     repeat N times:
    ///         let current = mutate(parent)
    ///         execute(current)
    ///         if current produced crashed:
    ///             output current
    ///         elif current resulted in a runtime exception or a time out:
    ///             // do nothing
    ///         elif current produced new, interesting behaviour:
    ///             minimize and add to corpus
    ///         else
    ///             parent = current
    ///
    ///
    /// This ensures that samples will be mutated multiple times as long
    /// as the intermediate results do not cause a runtime exception.
    public override func fuzzOne(_ group: DispatchGroup) {
        logger.verbose("A fuzzing round started.")
        var parent = fuzzer.corpus.randomElementForMutating()
        parent = prepareForMutating(parent)
        for _ in 0..<numConsecutiveMutations {
            // TODO: factor out code shared with the HybridEngine?
            var mutator = fuzzer.mutators.randomElement()
            let maxAttempts = 10
            var mutatedProgram: Program? = nil
            for _ in 0..<maxAttempts {
                if let result = mutator.mutate(parent, for: fuzzer) {
                    // Success!
                    result.contributors.formUnion(parent.contributors)
                    mutator.addedInstructions(result.size - parent.size)
                    let importants = getImportants(parent: parent, child: result)
                    result.updateImportants(newImportants: importants)
                    mutatedProgram = result
                    break
                } else {
                    // Try a different mutator.
                    mutator.failedToGenerate()
                    mutator = fuzzer.mutators.randomElement()
                }
            }

            guard let program = mutatedProgram else {
                logger.warning(
                    "Could not mutate sample, giving up. Sample:\n\(FuzzILLifter().lift(parent))")
                continue
            }

            assert(program !== parent)
            let outcome = execute(program)

            // Mutate the program further if it succeeded.
            if .succeeded == outcome {
                parent = program
            }
        }
    }

    /// Pre-processing of programs to facilitate mutations on them.
    private func prepareForMutating(_ program: Program) -> Program {
        let b = fuzzer.makeBuilder()
        b.buildPrefix()
        b.append(program)
        return b.finalize()
    }
}
