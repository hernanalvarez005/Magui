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

  const { data: before } = await serviceClient.auth.admin.getUserById(parsed.data.userId);
  const previousEmail = before?.user?.email ?? null;

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

  // El nombre queda auditado solo por el trigger de `profiles` (trg_audit_profiles).
  // El email vive en auth.users, fuera del alcance de ese trigger — se deja
  // constancia acá explícitamente, con quién lo hizo (profile.id, no la
  // service role key) y el antes/después.
  if (previousEmail !== parsed.data.email) {
    await serviceClient.from("audit_logs").insert({
      user_id: profile.id,
      action: "update_email",
      entity_type: "auth.users",
      entity_id: parsed.data.userId,
      metadata: { before: previousEmail, after: parsed.data.email },
    });
  }

  return { success: true };
}

const resetPasswordSchema = z.object({
  userId: z.string().uuid(),
  newPassword: z.string().min(8, "La contraseña debe tener al menos 8 caracteres."),
});

export interface ResetPasswordState {
  error?: string;
  success?: boolean;
}

// Acción administrativa pura: el admin ELIGE la contraseña nueva (nunca se
// genera ni se muestra la actual — no hace falta, Supabase Auth nunca la
// expone). No pide la contraseña anterior porque no es un cambio hecho por
// el propio usuario, es un reset administrativo. La contraseña nueva viaja
// una única vez, en el body de este POST hacia auth.admin — nunca se
// persiste en ninguna tabla propia ni se loguea (metadata: {} más abajo).
export async function resetUserPasswordAction(input: z.infer<typeof resetPasswordSchema>): Promise<ResetPasswordState> {
  const profile = await getCurrentProfile();
  if (profile.role !== "admin") {
    return { error: "No tenés permiso para cambiar contraseñas." };
  }

  const parsed = resetPasswordSchema.safeParse(input);
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? "Datos inválidos." };
  }

  let serviceClient;
  try {
    serviceClient = createServiceRoleClient();
  } catch {
    return { error: "Falta configurar SUPABASE_SERVICE_ROLE_KEY en el servidor." };
  }

  const { error } = await serviceClient.auth.admin.updateUserById(parsed.data.userId, {
    password: parsed.data.newPassword,
  });

  if (error) {
    return { error: error.message };
  }

  // Nunca se guarda el valor de la contraseña — solo el hecho de que se
  // cambió, quién lo hizo (el admin autenticado, no la service role) y a
  // quién.
  await serviceClient.from("audit_logs").insert({
    user_id: profile.id,
    action: "USER_PASSWORD_RESET",
    entity_type: "auth.users",
    entity_id: parsed.data.userId,
    metadata: {},
  });

  return { success: true };
}

const createUserSchema = z.object({
  email: z.string().trim().email(),
  password: z.string().min(8, "La contraseña debe tener al menos 8 caracteres."),
  fullName: z.string().trim().min(2),
  role: z.enum(["admin", "seller", "viewer"]),
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
  // Un viewer (modo observador) siempre ve reportes financieros — es lo que
  // vino a hacer — así que se fuerza acá para no depender de que alguien
  // marque el switch a mano al crearlo.
  const { error: updateError } = await serviceClient
    .from("profiles")
    .update({
      role: parsed.data.role,
      active: true,
      full_name: parsed.data.fullName,
      ...(parsed.data.role === "viewer" ? { can_view_financial_reports: true, can_adjust_stock: false } : {}),
    })
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
