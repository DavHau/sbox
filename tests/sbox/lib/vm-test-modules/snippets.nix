{ lib, config, ... }:
{
  options.testScriptSnippets = lib.mkOption {
    type = lib.types.listOf lib.types.lines;
    default = [ ];
    description = ''
      Python test script fragments concatenated (in module declaration order)
      into the final `testScript`. Makes the otherwise non-mergeable
      `testScript` composable across multiple modules.
    '';
  };

  config.testScript = lib.concatStringsSep "\n" config.testScriptSnippets;
}
