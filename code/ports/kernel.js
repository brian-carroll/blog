(function() {
  window.Elm = {
    Main: {
      wasm: initWasm,
    },
  };

  const subscribedOutPorts = {};
  const inPortPrefix = 'inPort$';

  function initWasm(filename, memorySpecs) {
    const memory = new WebAssembly.Memory(memorySpecs || { initial: 1 });
    return WebAssembly.compileStreaming(fetch(filename)).then(wasmModule => {
      const importObject = initImports(wasmModule, memory);
      return WebAssembly.instantiate(wasmModule, importObject).then(instance =>
        wrapInstance(instance, memory, importObject)
      );
    });
  }

  function initImports(wasmModule, memory) {
    const outPortNames = WebAssembly.Module.imports(wasmModule)
      .filter(imp => imp.module === 'outPorts')
      .map(port => port.name);

    const outPorts = {};
    for (let name of outPortNames) {
      // Pass a wrapper to Wasm and change implementation later when user calls 'subscribe' in JS
      outPorts[name] = function(byteOffset, numBytes) {
        subscribedOutPorts[name](byteOffset, numBytes);
      };
      // Initial implementation until user calls 'subscribe'
      subscribedOutPorts[name] = function() {
        console.warn(`Elm called an uninitialized port "${name}"`);
      };
    }
    return {
      outPorts,
      js: { mem: memory },
    };
  }

  function wrapInstance(instance, memory, importObject) {
    const wasmExports = instance.exports;
    const allocate = wasmExports.allocate;
    const elmApp = {
      ports: {},
      memory: memory,
    };
    for (let exportName in wasmExports) {
      if (exportName.startsWith(inPortPrefix)) {
        const portName = exportName.slice(inPortPrefix.length);
        elmApp.ports[portName] = wrapInPort(
          wasmExports,
          memory,
          allocate,
          exportName
        );
      }
    }
    for (let outPortName in importObject.outPorts) {
      elmApp.ports[outPortName] = setupOutputPort(memory, outPortName);
    }
    return elmApp;
  }

  function setupOutputPort(memory, outPortName) {
    return {
      subscribe: function(userFunction) {
        subscribedOutPorts[outPortName] = function(byteOffset, numBytes) {
          const codeUnits = new Uint16Array(
            memory.buffer,
            byteOffset,
            numBytes / 2
          );
          const json = new TextDecoder('utf-16le').decode(codeUnits);
          const obj = JSON.parse(json);
          userFunction(obj);
        };
      },
    };
  }

  function wrapInPort(wasmExports, memory, allocate, exportName) {
    return function(obj) {
      const json = JSON.stringify(obj);
      const jsonCodeUnits = json.length;
      const jsonBytes = jsonCodeUnits * 2;

      const memAddress = allocate(jsonBytes);
      const memView16 = new Uint16Array(
        memory.buffer,
        memAddress,
        jsonCodeUnits
      );
      for (let i = 0; i < jsonCodeUnits; i++) {
        memView16[i] = json.charCodeAt(i);
      }
      wasmExports[exportName](memAddress, jsonBytes);
    };
  }
})();
