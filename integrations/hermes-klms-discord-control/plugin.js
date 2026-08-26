import { PALETTE_AREA } from "@hermes/plugin-sdk";

const plugin = {
  id: "klms-discord-control",
  name: "KLMS Discord control",
  defaultEnabled: false,
  register(ctx) {
    ctx.register({
      id: "klms-sync-command",
      area: PALETTE_AREA,
      order: 70,
      data: {
        label: "KLMS: open /klms-sync control",
        run: () => ctx.host.navigate("/klms-sync"),
      },
    });
  },
};

export default plugin;
