// Nur für die lokale Typprüfung. Supabase/Deno liefern ihre echte Runtime.
declare const Deno: {
  env: {get(name: string): string | undefined};
  serve(handler: (request: Request) => Response | Promise<Response>): unknown;
};
