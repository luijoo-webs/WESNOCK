// =============================================================================
// WESNOCK — Edge Function: enviar-documento-venta
// Envía al cliente el comprobante (PDF "Documento interno / pre-factura") de una
// venta física. Se ejecuta en Supabase (servidor): el navegador nunca ve claves.
//
// Secretos requeridos (Supabase → Edge Functions → Secrets):
//   RESEND_API_KEY   clave de https://resend.com (u otro proveedor, adaptando sendEmail)
//   EMAIL_FROM       remitente verificado, p. ej. "WESNOCK <ventas@tudominio.com>"
// Supabase ya provee: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Seguridad: solo un usuario con rol 'admin' (tabla profiles) puede invocarla.
// El destinatario se toma de la venta en la base de datos, no del navegador.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const money = (n: number) => "$ " + Math.round(Number(n || 0)).toLocaleString("es-CO");
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function sendEmail(opts: { from: string; to: string; subject: string; html: string; filename: string; pdfBase64: string }) {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) throw new Error("EMAIL_NO_CONFIGURADO");
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: opts.from, to: [opts.to], subject: opts.subject, html: opts.html,
      attachments: [{ filename: opts.filename, content: opts.pdfBase64 }],
    }),
  });
  if (!r.ok) throw new Error("PROVEEDOR_EMAIL: " + (await r.text()).slice(0, 300));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "Método no permitido" });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const auth = req.headers.get("Authorization") ?? "";
    const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json(401, { error: "NO_AUTENTICADO" });

    const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: prof } = await db.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (prof?.role !== "admin") return json(403, { error: "NO_AUTORIZADO" });

    const { sale_id, pdf_base64 } = await req.json();
    if (!sale_id || !pdf_base64) return json(400, { error: "DATOS_INCOMPLETOS" });
    if (pdf_base64.length > 8_000_000) return json(413, { error: "PDF_DEMASIADO_GRANDE" });

    const { data: sale } = await db.from("sales").select("*, sale_items(*)").eq("id", sale_id).maybeSingle();
    if (!sale) return json(404, { error: "VENTA_NO_EXISTE" });
    const to = String(sale.cliente?.email || "").trim();
    if (!to) return json(400, { error: "CLIENTE_SIN_CORREO" });

    const { data: fac } = await db.from("store_settings").select("value").eq("key", "facturacion").maybeSingle();
    const f = fac?.value || {};
    const from = Deno.env.get("EMAIL_FROM");
    if (!from) return json(501, { error: "EMAIL_NO_CONFIGURADO" });
    const negocio = f.razonSocial || f.nombreComercial || "WESNOCK";

    const rows = (sale.sale_items || []).map((i: any) =>
      `<tr><td style="padding:6px 0">${esc(i.nombre)} <span style="color:#777">· ${esc(i.talla)}${i.color ? " · " + esc(i.color) : ""}</span></td>
       <td style="padding:6px 8px;text-align:center">${i.cantidad}</td><td style="padding:6px 0;text-align:right">${money(i.subtotal)}</td></tr>`).join("");
    const html = `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#111">
      <p style="letter-spacing:.3em;font-weight:800;font-size:18px;margin:0 0 24px">WESNOCK</p>
      <h1 style="font-size:20px;margin:0 0 8px">Gracias por tu compra, ${esc(String(sale.cliente?.nombre || "").split(" ")[0])}.</h1>
      <p style="color:#555;margin:0 0 20px">Te enviamos el comprobante de tu compra <b>${esc(sale.numero)}</b> en ${esc(negocio)}.</p>
      <table style="width:100%;border-collapse:collapse;font-size:14px;border-top:1px solid #ddd;border-bottom:1px solid #ddd">${rows}</table>
      <p style="text-align:right;font-size:16px;margin:14px 0"><b>Total: ${money(sale.total)}</b></p>
      <p style="font-size:12px;color:#777;border:1px dashed #ccc;padding:10px">El archivo adjunto es un <b>documento interno / pre-factura</b> generado por ${esc(negocio)}.
      No constituye una factura electrónica de venta validada por la DIAN.</p>
      ${f.textoPie ? `<p style="font-size:13px;color:#555">${esc(f.textoPie)}</p>` : ""}</div>`;

    await sendEmail({ from, to, subject: `Tu compra en ${negocio} — ${sale.numero}`, html, filename: `${sale.numero}.pdf`, pdfBase64: pdf_base64 });
    await db.from("sales").update({ email_enviado_at: new Date().toISOString(), email_destino: to }).eq("id", sale.id);
    return json(200, { ok: true, to });
  } catch (e) {
    const msg = String((e as Error)?.message || e);
    return json(msg === "EMAIL_NO_CONFIGURADO" ? 501 : 500, { error: msg });
  }
});
