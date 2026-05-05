import { main } from "./cli";

process.stdout.on("error", (error: any) => {
  if (error?.code === "EPIPE") {
    process.exit(0);
  }
  throw error;
});

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (error: any) => {
    process.stderr.write(`${error.stack ?? error.message}\n`);
    process.exitCode = 1;
  }
);
