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

import Fuzzilli

fileprivate let ForceJITCompilationThroughLoopGenerator = CodeGenerator("ForceJITCompilationThroughLoopGenerator", input: .function()) { b, f in
    // The MutationEngine may use variables of unknown type as input as well, however, we only want to call functions that we generated ourselves. Further, attempting to call a non-function will result in a runtime exception.
    // For both these reasons, we abort here if we cannot prove that f is indeed a function.
    guard b.type(of: f).Is(.function()) else { return }
    let arguments = b.randomArguments(forCalling: f)

    b.buildRepeatLoop(n: 100) { _ in
        b.callFunction(f, withArgs: arguments)
    }
}

fileprivate let ForceTurboFanCompilationGenerator = CodeGenerator("ForceTurboFanCompilationGenerator", input: .function()) { b, f in
    // See comment in ForceJITCompilationThroughLoopGenerator.
    guard b.type(of: f).Is(.function()) else { return }
    let arguments = b.randomArguments(forCalling: f)

    b.callFunction(f, withArgs: arguments)

    b.eval("%PrepareFunctionForOptimization(%@)", with: [f]);

    b.callFunction(f, withArgs: arguments)
    b.callFunction(f, withArgs: arguments)

    b.eval("%OptimizeFunctionOnNextCall(%@)", with: [f]);

    b.callFunction(f, withArgs: arguments)
}

fileprivate let ForceMaglevCompilationGenerator = CodeGenerator("ForceMaglevCompilationGenerator", input: .function()) { b, f in
    // See comment in ForceJITCompilationThroughLoopGenerator.
    guard b.type(of: f).Is(.function()) else { return }
    let arguments = b.randomArguments(forCalling: f)

    b.callFunction(f, withArgs: arguments)

    b.eval("%PrepareFunctionForOptimization(%@)", with: [f]);

    b.callFunction(f, withArgs: arguments)
    b.callFunction(f, withArgs: arguments)

    b.eval("%OptimizeMaglevOnNextCall(%@)", with: [f]);

    b.callFunction(f, withArgs: arguments)
}

fileprivate let TurbofanVerifyTypeGenerator = CodeGenerator("TurbofanVerifyTypeGenerator", input: .anything) { b, v in
    b.eval("%VerifyType(%@)", with: [v])
}

fileprivate let WorkerGenerator = RecursiveCodeGenerator("WorkerGenerator") { b in
    let workerSignature = Signature(withParameterCount: Int.random(in: 0...3))

    // TODO(cffsmith): currently Fuzzilli does not know that this code is sent
    // to another worker as a string. This has the consequence that we might
    // use variables inside the worker that are defined in a different scope
    // and as such they are not accessible / undefined. To fix this we should
    // define an Operation attribute that tells Fuzzilli to ignore variables
    // defined in outer scopes.
    let workerFunction = b.buildPlainFunction(with: .parameters(workerSignature.parameters)) { args in
        let this = b.loadThis()

        // Generate a random onmessage handler for incoming messages.
        let onmessageFunction = b.buildPlainFunction(with: .parameters(n: 1)) { args in
            b.buildRecursive(block: 1, of: 2)
        }
        b.setProperty("onmessage", of: this, to: onmessageFunction)

        b.buildRecursive(block: 2, of: 2)
    }
    let workerConstructor = b.loadBuiltin("Worker")

    let functionString = b.loadString("function")
    let argumentsArray = b.createArray(with: b.randomArguments(forCalling: workerFunction))

    let configObject = b.createObject(with: ["type": functionString, "arguments": argumentsArray])

    let worker = b.construct(workerConstructor, withArgs: [workerFunction, configObject])
    // Fuzzilli can now use the worker.
}

fileprivate let SerializeDeserializeGenerator = CodeGenerator("SerializeDeserializeGenerator", input: .object()) { b, o in
    // Load necessary builtins
    let d8 = b.loadBuiltin("d8")
    let serializer = b.getProperty("serializer", of: d8)
    let Uint8Array = b.loadBuiltin("Uint8Array")

    // Serialize a random object
    let content = b.callMethod("serialize", on: serializer, withArgs: [o])
    let u8 = b.construct(Uint8Array, withArgs: [content])

    // Choose a random byte to change
    let index = Int64.random(in: 0..<100)

    // Either flip or replace the byte
    let newByte: Variable
    if probability(0.5) {
        let bit = b.loadInt(1 << Int.random(in: 0..<8))
        let oldByte = b.getElement(index, of: u8)
        newByte = b.binary(oldByte, bit, with: .Xor)
    } else {
        newByte = b.loadInt(Int64.random(in: 0..<256))
    }
    b.setElement(index, of: u8, to: newByte)

    // Deserialize the resulting buffer
    let _ = b.callMethod("deserialize", on: serializer, withArgs: [content])

    // Deserialized object is available in a variable now and can be used by following code
}

// Insert random GC calls throughout our code.
fileprivate let GcGenerator = CodeGenerator("GcGenerator") { b in
    let gc = b.loadBuiltin("gc")

    // Do minor GCs more frequently.
    let type = b.loadString(probability(0.25) ? "major" : "minor")
    // If the execution type is 'async', gc() returns a Promise, we currently
    // do not really handle other than typing the return of gc to .undefined |
    // .jsPromise. One could either chain a .then or create two wrapper
    // functions that are differently typed such that fuzzilli always knows
    // what the type of the return value is.
    let execution = b.loadString(probability(0.5) ? "sync" : "async")
    b.callFunction(gc, withArgs: [b.createObject(with: ["type": type, "execution": execution])])
}

fileprivate let MapTransitionsTemplate = ProgramTemplate("MapTransitionsTemplate") { b in
    // This template is meant to stress the v8 Map transition mechanisms.
    // Basically, it generates a bunch of CreateObject, GetProperty, SetProperty, FunctionDefinition,
    // and CallFunction operations operating on a small set of objects and property names.

    let propertyNames = b.fuzzer.environment.customProperties
    assert(Set(propertyNames).isDisjoint(with: b.fuzzer.environment.customMethods))

    // Use this as base object type. For one, this ensures that the initial map is stable.
    // Moreover, this guarantees that when querying for this type, we will receive one of
    // the objects we created and not e.g. a function (which is also an object).
    assert(propertyNames.contains("a"))
    let objType = JSType.object(withProperties: ["a"])

    // Keep track of all objects created in this template so that they can be verified at the end.
    var objects = [Variable]()

    // Helper function to pick random properties and values.
    func randomProperties(in b: ProgramBuilder) -> ([String], [Variable]) {
        if !b.hasVisibleVariables {
            // Use integer values if there are no visible variables, which should be a decent fallback.
            b.loadInt(b.randomInt())
        }

        var properties = ["a"]
        var values = [b.randomVariable()]
        for _ in 0..<3 {
            let property = chooseUniform(from: propertyNames)
            guard !properties.contains(property) else { continue }
            properties.append(property)
            values.append(b.randomVariable())
        }
        assert(Set(properties).count == values.count)
        return (properties, values)
    }

    // Temporarily overwrite the active code generators with the following generators...
    let primitiveValueGenerator = ValueGenerator("PrimitiveValue") { b, n in
        for _ in 0..<n {
            // These should roughly correspond to the supported property representations of the engine.
            withEqualProbability({
                b.loadInt(b.randomInt())
            }, {
                b.loadFloat(b.randomFloat())
            }, {
                b.loadString(b.randomString())
            })
        }
    }
    let createObjectGenerator = ValueGenerator("CreateObject") { b, n in
        for _ in 0..<n {
            let (properties, values) = randomProperties(in: b)
            let obj = b.createObject(with: Dictionary(uniqueKeysWithValues: zip(properties, values)))
            assert(b.type(of: obj).Is(objType))
            objects.append(obj)
        }
    }
    let objectMakerGenerator = ValueGenerator("ObjectMaker") { b, n in
        let f = b.buildPlainFunction(with: b.randomParameters()) { args in
            let (properties, values) = randomProperties(in: b)
            let o = b.createObject(with: Dictionary(uniqueKeysWithValues: zip(properties, values)))
            b.doReturn(o)
        }
        for _ in 0..<n {
            let obj = b.callFunction(f, withArgs: b.randomArguments(forCalling: f))
            assert(b.type(of: obj).Is(objType))
            objects.append(obj)
        }
    }
    let objectConstructorGenerator = ValueGenerator("ObjectConstructor") { b, n in
        let c = b.buildConstructor(with: b.randomParameters()) { args in
            let this = args[0]
            let (properties, values) = randomProperties(in: b)
            for (p, v) in zip(properties, values) {
                b.setProperty(p, of: this, to: v)
            }
        }
        for _ in 0..<n {
            let obj = b.construct(c, withArgs: b.randomArguments(forCalling: c))
            assert(b.type(of: obj).Is(objType))
            objects.append(obj)
        }
    }
    let propertyLoadGenerator = CodeGenerator("PropertyLoad", input: objType) { b, obj in
        b.getProperty(chooseUniform(from: propertyNames), of: obj)
    }
    let propertyStoreGenerator = CodeGenerator("PropertyStore", input: objType) { b, obj in
        let numProperties = Int.random(in: 1...4)
        for _ in 0..<numProperties {
            b.setProperty(chooseUniform(from: propertyNames), of: obj, to: b.randomVariable())
        }
    }
    let functionDefinitionGenerator = RecursiveCodeGenerator("FunctionDefinition") { b in
        let prevSize = objects.count

        // We use either a randomly generated signature or a fixed on that ensures we use our object type frequently.
        var parameters = b.randomParameters()
        if probability(0.5) && !objects.isEmpty {
            parameters = .parameters(.plain(objType), .plain(objType), .anything, .anything)
        }

        let f = b.buildPlainFunction(with: parameters) { params in
            for p in params where b.type(of: p).Is(objType) {
                objects.append(p)
            }
            b.buildRecursive()
            b.doReturn(b.randomVariable())
        }
        objects.removeLast(objects.count - prevSize)

        for _ in 0..<3 {
            let rval = b.callFunction(f, withArgs: b.randomArguments(forCalling: f))
            if b.type(of: rval).Is(objType) {
                objects.append(rval)
            }
        }
    }
    let functionCallGenerator = CodeGenerator("FunctionCall", input: .function()) { b, f in
        let rval = b.callFunction(f, withArgs: b.randomArguments(forCalling: f))
        if b.type(of: rval).Is(objType) {
            objects.append(rval)
        }
    }
    let constructorCallGenerator = CodeGenerator("ConstructorCall", input: .constructor()) { b, f in
        let rval = b.construct(f, withArgs: b.randomArguments(forCalling: f))
        if b.type(of: rval).Is(objType) {
            objects.append(rval)
        }
     }
    let functionJitCallGenerator = CodeGenerator("FunctionJitCall", input: .function()) { b, f in
        let args = b.randomArguments(forCalling: f)
        b.buildRepeatLoop(n: 100) { _ in
            b.callFunction(f, withArgs: args)       // Rval goes out-of-scope immediately, so no need to track it
        }
    }

    let prevCodeGenerators = b.fuzzer.codeGenerators
    b.fuzzer.setCodeGenerators(WeightedList<CodeGenerator>([
        (primitiveValueGenerator,     2),
        (createObjectGenerator,       1),
        (objectMakerGenerator,        1),
        (objectConstructorGenerator,  1),
        (propertyLoadGenerator,       2),
        (propertyStoreGenerator,      5),
        (functionDefinitionGenerator, 1),
        (functionCallGenerator,       2),
        (constructorCallGenerator,    1),
        (functionJitCallGenerator,    1)
    ]))

    // ... run some of the ValueGenerators to create some initial objects ...
    b.buildValues(5)
    // ... and generate a bunch of code.
    b.build(n: 100, by: .generating)

    // Now, restore the previous code generators and generate some more code.
    b.fuzzer.setCodeGenerators(prevCodeGenerators)
    b.build(n: 10)

    // Finally, run HeapObjectVerify on all our generated objects (that are still in scope).
    for obj in objects {
        b.eval("%HeapObjectVerify(%@)", with: [obj])
    }
}

// This template fuzzes the RegExp engine.
// It finds bugs like: crbug.com/1437346 and crbug.com/1439691.
fileprivate let RegExpFuzzerTemplate = ProgramTemplate("RegExpFuzzerTemplate") { b in
    // Taken from: https://source.chromium.org/chromium/chromium/src/+/refs/heads/main:v8/test/fuzzer/regexp-builtins.cc;l=212;drc=a61b95c63b0b75c1cfe872d9c8cdf927c226046e
    let twoByteSubjectString = "f\\uD83D\\uDCA9ba\\u2603"

    let replacementCandidates = [
      "'X'",
      "'$1$2$3'",
      "'$$$&$`$\\'$1'",
      "() => 'X'",
      "(arg0, arg1, arg2, arg3, arg4) => arg0 + arg1 + arg2 + arg3 + arg4",
      "() => 42"
    ]

    let lastIndices = [
      "undefined",  "-1",         "0",
      "1",          "2",          "3",
      "4",          "5",          "6",
      "7",          "8",          "9",
      "50",         "4294967296", "2147483647",
      "2147483648", "NaN",        "Not a Number"
    ]

    let f = b.buildPlainFunction(with: .parameters(n: 0)) { _ in
        let pattern = probability(0.5) ? chooseUniform(from: b.fuzzer.environment.interestingRegExps) : b.randomString()
        let regExpVar = b.loadRegExp(pattern, RegExpFlags.random())

        let lastIndex = chooseUniform(from: lastIndices)
        let lastIndexString = b.loadString(lastIndex)

        b.setProperty("lastIndex", of: regExpVar, to: lastIndexString)

        let subjectVar: Variable

        if probability(0.1) {
            subjectVar = b.loadString(twoByteSubjectString)
        } else {
            subjectVar = b.loadString(b.randomString())
        }

        let resultVar = b.loadNull()

        b.buildTryCatchFinally(tryBody: {
            let symbol = b.loadBuiltin("Symbol")
            withEqualProbability({
                let res = b.callMethod("exec", on: regExpVar, withArgs: [subjectVar])
                b.reassign(resultVar, to: res)
            }, {
                let prop = b.getProperty("match", of: symbol)
                let res = b.callComputedMethod(prop, on: regExpVar, withArgs: [subjectVar])
                b.reassign(resultVar, to: res)
            }, {
                let prop = b.getProperty("replace", of: symbol)
                let replacement = withEqualProbability({
                    b.loadString(b.randomString())
                }, {
                    b.loadString(chooseUniform(from: replacementCandidates))
                })
                let res = b.callComputedMethod(prop, on: regExpVar, withArgs: [subjectVar, replacement])
                b.reassign(resultVar, to: res)
            }, {
                let prop = b.getProperty("search", of: symbol)
                let res = b.callComputedMethod(prop, on: regExpVar, withArgs: [subjectVar])
                b.reassign(resultVar, to: res)
            }, {
                let prop = b.getProperty("split", of: symbol)
                let randomSplitLimit = withEqualProbability({
                    "undefined"
                }, {
                    "'not a number'"
                }, {
                    String(b.randomInt())
                })
                let limit = b.loadString(randomSplitLimit)
                let res = b.callComputedMethod(symbol, on: regExpVar, withArgs: [subjectVar, limit])
                b.reassign(resultVar, to: res)
            }, {
                let res = b.callMethod("test", on: regExpVar, withArgs: [subjectVar])
                b.reassign(resultVar, to: res)
            })
        }, catchBody: { _ in
        })

        b.build(n: 7)

        b.doReturn(resultVar)
    }

    b.eval("%SetForceSlowPath(false)");
    // compile the regexp once
    b.callFunction(f)
    let resFast = b.callFunction(f)
    b.eval("%SetForceSlowPath(true)");
    let resSlow = b.callFunction(f)
    b.eval("%SetForceSlowPath(false)");

    b.build(n: 15)
}

let v8Profile = Profile(
    processArgs: { randomize in
        var args = [
            "--allow-natives-syntax",
            "--fuzzing",
            "--jit-fuzzing",
        ]
        return args
    },

    processEnv: [:],

    maxExecsBeforeRespawn: 1000,

    timeout: 250,

    codePrefix: """
     function classOf(object) {
       var string = Object.prototype.toString.call(object);
       return string.substring(8, string.length - 1);
    }
    function deepObjectEquals(a, b) {
      var aProps = Object.keys(a);
      aProps.sort();
      var bProps = Object.keys(b);
      bProps.sort();
      if (!deepEquals(aProps, bProps)) {
        return false;
      }
      for (var i = 0; i < aProps.length; i++) {
        if (!deepEquals(a[aProps[i]], b[aProps[i]])) {
          return false;
        }
      }
      return true;
    }
    function deepEquals(a, b) {
      if (a === b) {
        if (a === 0) return (1 / a) === (1 / b);
        return true;
      }
      if (typeof a != typeof b) return false;
      if (typeof a == 'number') return (isNaN(a) && isNaN(b)) || (a===b);
      if (typeof a == 'string') return a.length == 55 && a.toString().search(" GMT") !== -1;
      if (typeof a !== 'object' && typeof a !== 'function' && typeof a !== 'symbol') return false;
      var objectClass = classOf(a);
      if (objectClass !== classOf(b)) return false;
      if (objectClass === 'RegExp') {
        return (a.toString() === b.toString());
      }
      if (objectClass === 'Function') return false;
      if (objectClass === 'Array') {
        var elementCount = 0;
        if (a.length != b.length) {
          return false;
        }
        for (var i = 0; i < a.length; i++) {
          if (!deepEquals(a[i], b[i])) return false;
        }
        return true;
      }
      if (objectClass !== classOf(b)) return false;
      if (objectClass === 'RegExp') {
        return (a.toString() === b.toString());
      }
      if (objectClass === 'Function') return true;
      if (objectClass == 'String' || objectClass == 'Number' ||
          objectClass == 'Boolean' || objectClass == 'Date') {
        if (a.valueOf() !== b.valueOf()) return false;
      }
      return deepObjectEquals(a, b);
    }
    function opt(p0, p1){
    """,

    codeSuffix: """
     }
    let jit_before = opt(false, 0);
    opt(true, 0);
    %PrepareFunctionForOptimization(opt);
    opt(true, 0);
    %OptimizeFunctionOnNextCall(opt)
    let jit_after = opt(false, 0);
    if (jit_before === undefined && jit_after === undefined){
        opt(false, 0);
    } else if (!deepEquals(jit_before, jit_after)) {
        fuzzilli('FUZZILLI_CRASH', 0);
    }
    """,

    ecmaVersion: ECMAScriptVersion.es6,

    crashTests: ["fuzzilli('FUZZILLI_CRASH', 0)", "fuzzilli('FUZZILLI_CRASH', 1)", "fuzzilli('FUZZILLI_CRASH', 2)"],

    additionalCodeGenerators: [],

    additionalProgramTemplates: WeightedList<ProgramTemplate>([]),

    // disable generators that generates not targeted operators by TurboTV.
    disabledCodeGenerators: [
        // Loop
        "WhileLoopGenerator",
        "DoWhileLoopGenerator",
        "SimpleForLoopGenerator",
        "ComplexForLoopGenerator",
        "ForInLoopGenerator",
        "ForOfLoopGenerator",
        "ForOfWithDestructLoopGenerator",
        "RepeatLoopGenerator",
        "LoopBreakGenerator",
        "ContinueGenerator",

        // Asynchronous
        "AsyncFunctionGenerator",
        "AsyncArrowFunctionGenerator",
        "AsyncGeneratorFunctionGenerator",
        "AwaitGenerator",
        "PromiseGenerator",

        // Computed
        "ComputedPropertyRetrievalGenerator",
        "ComputedPropertyAssignmentGenerator",
        "StoreComputedPropertyWithBinopGenerator",
        "ComputedPropertyRemovalGenerator",
        "ComputedPropertyConfigurationGenerator",
        "ComputedMethodCallGenerator",
        "ComputedMethodCallWithSpreadGenerator",
        "ComputedPropertyUpdateGenerator",

        // Well-known property access
        "WellKnownPropertyLoadGenerator",
        "WellKnownPropertyStoreGenerator",
        "PrototypeAccessGenerator",
        "PrototypeOverwriteGenerator",

        // Class
        "ClassGenerator",
        "ClassConstructorGenerator",
        "ClassDefinitionGenerator",
        "ClassInstanceComputedPropertyGenerator",
        "ClassInstanceElementGenerator",
        "ClassInstanceGetterGenerator",
        "ClassInstanceMethodGenerator",
        "ClassInstancePropertyGenerator",
        "ClassInstanceSetterGenerator",
        "ClassPrivateInstanceMethodGenerator",
        "ClassPrivateInstancePropertyGenerator",
        "ClassPrivateStaticMethodGenerator",
        "ClassPrivateStaticPropertyGenerator",
        "ClassStaticComputedPropertyGenerator",
        "ClassStaticElementGenerator",
        "ClassStaticGetterGenerator",
        "ClassStaticInitializerGenerator",
        "ClassStaticMethodGenerator",
        "ClassStaticPropertyGenerator",
        "ClassStaticSetterGenerator",
        "PrivateMethodCallGenerator",
        "PrivatePropertyAssignmentGenerator",
        "PrivatePropertyRetrievalGenerator",
        "PrivatePropertyUpdateGenerator",
        // "MethodCallGenerator", required for 1404607, 1323114
        "MethodCallWithSpreadGenerator",
        "ConstructorCallGenerator",
        "ConstructorCallWithSpreadGenerator",
        // "ConstructorGenerator",  required for 1404607
        "SuperMethodCallGenerator",
        "LoadSuperPropertyGenerator",
        "SuperPropertyAssignmentGenerator",
        "SuperPropertyRetrievalGenerator",
        "SuperPropertyUpdateGenerator",
        "ThisGenerator",

        // Object
        "BuiltinObjectInstanceGenerator",
        "ObjectWithSpreadGenerator",
        "ObjectBuilderFunctionGenerator",
        "ObjectConstructorGenerator",
        "ObjectLiteralComputedMethodGenerator",
        "ObjectLiteralComputedPropertyGenerator",
        "ObjectLiteralCopyPropertiesGenerator",
        "ObjectLiteralElementGenerator",
        // "ObjectLiteralGenerator",
        // "ObjectLiteralPropertyGenerator",
        "ObjectLiteralGetterGenerator",
        "ObjectLiteralMethodGenerator",
        "ObjectLiteralPrototypeGenerator",
        "ObjectLiteralSetterGenerator",
        "DestructObjectAndReassignGenerator",
        "DestructObjectGenerator",
        // "PropertyAssignmentGenerator", required for 1323114
        "PropertyUpdateGenerator",
        "PropertyConfigurationGenerator",
        "PropertyRemovalGenerator",
        "PropertyRetrievalGenerator",

        // RegExp
        "RegExpGenerator",

        // String
        "StringGenerator",
        "TemplateStringGenerator",

        // Function
        "TrivialFunctionGenerator",
        "ArrowFunctionGenerator",
        "GeneratorFunctionGenerator",
        "PlainFunctionGenerator",
        "FunctionCallGenerator",
        "FunctionCallWithSpreadGenerator",

        // Symbol-related
        "IteratorGenerator",

        // Misc
        // "TryCatchGenerator", // 1404607
        "TypedArrayGenerator",
        "ImitationGenerator",
        "ResizableArrayBufferGenerator",
        "DestructArrayAndReassignGenerator",
        "DestructArrayGenerator",
        "GrowableSharedArrayBufferGenerator",
        "FunctionCallWithSpreadGenerator",
        "CallbackPropertyGenerator",
        "ThrowGenerator",
        "YieldGenerator",
        "TypeTestGenerator",
        "ArrayWithSpreadGenerator",
        "TemplateStringGenerator",
        "StringNormalizeGenerator",
        "InstanceOfGenerator",
        "InGenerator",
        "MethodCallWithDifferentThisGenerator",
        "ProxyGenerator",
        "LengthChangeGenerator",
        "EvalGenerator",
        "JITFunctionGenerator",
        "WithStatementGenerator",
        "ElementAssignmentGenerator",
        "ElementConfigurationGenerator",
        "ElementKindChangeGenerator",
        "ElementRemovalGenerator",
        "ElementRetrievalGenerator",
        "WeirdClassGenerator",
        "FastToSlowPropertiesGenerator",

        // More-constrained
        "UndefinedGenerator",
        "NullGenerator",
        "ArrayGenerator",
        "IntArrayGenerator",
        "FloatArrayGenerator",
        "TypedArrayGenerator",
        "ElementUpdateGenerator", // a[3]=..
        "BlockStatementGenerator",
        "SwitchBlockGenerator",
        "SwitchCaseBreakGenerator",
        "SwitchCaseGenerator",
        "SwitchDefaultCaseGenerator",
        "ArgumentsGenerator",
        "DupGenerator",
        "CompareWithIfElseGenerator",
        "UnaryOperationGenerator",
        "UpdateGenerator", // a += 3 ...
        "NumberComputationGenerator",
        "ConstructorGenerator",
        "NamedVariableDefinitionGenerator",
        "NamedVariableLoadGenerator",
        "NamedVariableStoreGenerator",
        "SubroutineReturnGenerator",

        // constrain for 1199345, 1200490, 1234764, 1234770
        "BigIntGenerator",
        "BooleanGenerator",
        "BuiltinGenerator",
        "MethodCallGenerator",
        "ObjectLiteralGenerator",
        "ObjectLiteralElementGenerator",
        "ObjectLiteralPropertyGenerator",
        "PropertyAssignmentGenerator",
        "TryCatchGenerator",
        "TernaryOperationGenerator",
        ],

    additionalBuiltins: [:]
)
