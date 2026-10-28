import { startPackagesService } from "@jxsuite/server/packages-service";

await startPackagesService(Number(process.env.PORT ?? 8080));
