{
  description = "Collection of Nix Flake Templates";

  outputs = { self, ... }: {
    templates = {
      zig = {
        path = ./templates/zig;
        description = "Zig Baseline Template";
      };
      defaultTemplate = self.templates.zig;
    };
  };
}
