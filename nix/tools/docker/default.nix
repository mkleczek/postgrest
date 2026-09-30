{
  buildToolbox,
  postgrest,
  dockerTools,
  checkedShellScript,
}:
let
  image = dockerTools.buildImage {
    name = "postgrest";
    tag = "latest";
    # CA certificates verify the servers PostgREST requests over HTTPS, e.g.
    # the issuer's keys with jwt-oidc-discovery. Mounting a bundle over
    # /etc/ssl/certs replaces them.
    copyToRoot = [
      postgrest
      dockerTools.caCertificates
    ];

    # Set the current time as the image creation date. This makes the build
    # non-reproducible, but that should not be an issue for us.
    created = "now";

    extraCommands = ''
      rmdir share
    '';

    config = {
      Cmd = [ "/bin/postgrest" ];
      User = "1000";
      ExposedPorts = {
        "3000/tcp" = { };
      };
    };
  };

  load =
    checkedShellScript
      {
        name = "postgrest-docker-load";
        docs = "Load the PostgREST image into Docker.";
      }
      ''
        docker load -i ${image}
      '';

in
buildToolbox {
  name = "postgrest-docker";
  tools = { inherit load; };
  extra = { inherit image; };
}
