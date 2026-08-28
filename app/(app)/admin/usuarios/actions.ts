"use server";

import { z } from "zod";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createServiceRoleClient } from "@/lib/supabase/server";

const updateUserSchema = z.object({
  userId: z.string().uuid(),
  fullName: z.string().trim().min(2, "Ingresá un nombre válido."),
  email: z.string().trim().email("Ese email no es válido."),
});

export interface UpdateUserState {
  error?: string;
  success?: boolean;
}

// Edita nombre/email de un usuario ya existente. El nombre vive en profiles
// (RLS de la app); el email vive únicamente en auth.users — profiles nunca
// tuvo columna email — así que sincronizarlo requiere sí o sí la Auth Admin
// API (service_role). Nunca se expone la service role key al navegador: esta
// función corre server-side (Server Action).
export async function updateUserAction(input: z.infer<typeof updateUserSchema>): Promise<UpdateUserState> {
  const profile = await getCurrentProfile();
  if (profile.role !== "admin") {
    return { error: "No tenés permiso para editar usuarios." };
  }

  const parsed = updateUserSchema.safeParse(input);
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? "Datos inválidos." };
  }

  let serviceClient;
  try {
    serviceClient = createServiceRoleClient();
  } catch {
    return { error: "Falta configurar SUPABASE_SERVICE_ROLE_KEY en el servidor." };
  }

  const { error: authError } = await serviceClient.auth.admin.updateUserById(parsed.data.userId, {
    email: parsed.data.email,
    email_confirm: true,
    user_metadata: { full_name: parsed.data.fullName },
  });

  if (authError) {
    return {
      error: authError.message.includes("already been registered")
        ? "Ya existe otro usuario con ese email."
        : authError.message,
    };
  }

  const { error: profileError } = await serviceClient
    .from("profiles")
    .update({ full_name: parsed.data.fullName })
    .eq("id", parsed.data.userId);

  if (profileError) {
    return { error: "El email se actualizó pero no pudimos guardar el nombre. Volvé a intentar." };
  }

  return { success: true };
}

function generateTempPassword() {
  // 12 caracteres, alfanumérico + símbolo, generado server-side. Nunca se
  // guarda en ninguna tabla ni se loguea — viaja solo en la respuesta de
  // esta Server Action, para que el admin se lo pase a la persona una vez.
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const bytes = new Uint32Array(12);
  crypto.getRandomValues(bytes);
  let password = "";
  for (const b of bytes) password += alphabet[b % alphabet.length];
  return `${password}!`;
}

export interface ResetPasswordState {
  error?: string;
  tempPassword?: string;
}

export async function resetUserPasswordAction(userId: string): Promise<ResetPasswordState> {
  const profile = await getCurrentProfile();
  if (profile.role !== "admin") {
    return { error: "No tenés permiso para restablecer contraseñas." };
  }

  const parsedId = z.string().uuid().safeParse(userId);
  if (!parsedId.success) {
    return { error: "Usuario inválido." };
  }

  let serviceClient;
  try {
    serviceClient = createServiceRoleClient();
  } catch {
    return { error: "Falta configurar SUPABASE_SERVICE_ROLE_KEY en el servidor." };
  }

  const tempPassword = generateTempPassword();
  const { error } = await serviceClient.auth.admin.updateUserById(parsedId.data, { password: tempPassword });

  if (error) {
    return { error: error.message };
  }

  return { tempPassword };
}

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
