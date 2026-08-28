"use server";

import { z } from "zod";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createServiceRoleClient } from "@/lib/supabase/server";

const createUserSchema = z.object({
  email: z.string().trim().email(),
  password: z.string().min(8, "La contraseña debe tener al menos 8 caracteres."),
  fullName: z.string().trim().min(2),
  role: z.enum(["admin", "seller"]),
  locationIds: z.array(z.string().uuid()),
});

export interface CreateUserState {
  error?: string;
  success?: boolean;
}

export async function createUserAction(input: z.infer<typeof createUserSchema>): Promise<CreateUserState> {
  const profile = await getCurrentProfile();
  if (profile.role !== "admin") {
    return { error: "No tenés permiso para crear usuarios." };
  }

  const parsed = createUserSchema.safeParse(input);
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? "Datos inválidos." };
  }

  let serviceClient;
  try {
    serviceClient = createServiceRoleClient();
  } catch {
    return {
      error:
        "Falta configurar SUPABASE_SERVICE_ROLE_KEY en el servidor. Pedile a un desarrollador que la agregue.",
    };
  }

  const { data: created, error: createError } = await serviceClient.auth.admin.createUser({
    email: parsed.data.email,
    password: parsed.data.password,
    email_confirm: true,
    user_metadata: { full_name: parsed.data.fullName },
  });

  if (createError || !created.user) {
    return { error: createError?.message ?? "No pudimos crear el usuario." };
  }

  const userId = created.user.id;

  // El trigger handle_new_auth_user ya creó profiles(role='seller', active=false).
  const { error: updateError } = await serviceClient
    .from("profiles")
    .update({ role: parsed.data.role, active: true, full_name: parsed.data.fullName })
    .eq("id", userId);

  if (updateError) {
    return { error: "El usuario se creó pero no pudimos activarlo. Hacelo desde la lista." };
  }

  if (parsed.data.locationIds.length > 0) {
    await serviceClient
      .from("profile_locations")
      .insert(parsed.data.locationIds.map((locationId) => ({ profile_id: userId, location_id: locationId })));
  }

  return { success: true };
}
