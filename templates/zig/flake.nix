{
  inputs.flakelight-zig.url = "github:accelbread/flakelight-zig";
  outputs = { flakelight-zig, ... }: flakelight-zig ./. {
    license = "WTFPL";
    templates = {
      defaultTemplate = {
        path = ./template;
        description = "Zig Baseline Template";
      };
    };
  };
}
