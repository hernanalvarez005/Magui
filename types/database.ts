// Tipos de la base de datos, escritos a mano a partir de supabase/migrations/*.sql
// (no hay proyecto Supabase en vivo todavía para correr `supabase gen types`).
// Mantener sincronizado con el esquema. Formato compatible con @supabase/supabase-js v2.

export type AppRole = "admin" | "seller";
export type StockLocationType = "branch" | "warehouse";
export type ProductType = "product" | "accessory" | "kit";
export type PriceRuleType = "BASE" | "PAYMENT_METHOD" | "QUANTITY";
export type SaleStatus = "draft" | "confirmed" | "cancelled";
export type StockMovementType =
  | "INITIAL"
  | "PURCHASE"
  | "SALE"
  | "SALE_CANCEL"
  | "ADJUSTMENT_PLUS"
  | "ADJUSTMENT_MINUS"
  | "ADJUSTMENT_SET"
  | "TRANSFER_OUT"
  | "TRANSFER_IN"
  | "RETURN";
export type StockTransferStatus = "confirmed" | "cancelled";
export type StockAdjustmentReason =
  | "RECEPTION"
  | "BREAKAGE"
  | "EXPIRATION"
  | "COUNT_DIFFERENCE"
  | "RETURN"
  | "OTHER";
export type FreeSaleReason = "GIFT" | "SAMPLE" | "EXCHANGE" | "COURTESY" | "OTHER";
export type PromotionType = "THREE_FOR_TWO" | "DUO_PERCENT" | "KIT_PERCENT";

// ---------------------------------------------------------------------------
// Row shapes (una interfaz por tabla/vista)
// ---------------------------------------------------------------------------

export type ProfileRow = {
  id: string;
  full_name: string;
  role: AppRole;
  active: boolean;
  can_view_financial_reports: boolean;
  can_adjust_stock: boolean;
  created_at: string;
  updated_at: string;
};

export type ProfileLocationRow = {
  profile_id: string;
  location_id: string;
  created_at: string;
};

export type StockLocationRow = {
  id: string;
  code: string;
  short_code: string;
  name: string;
  type: StockLocationType;
  active: boolean;
  created_at: string;
  updated_at: string;
};

export type SalesChannelRow = {
  id: string;
  code: string;
  name: string;
  active: boolean;
  sort_order: number;
  created_at: string;
  updated_at: string;
};

export type PaymentMethodRow = {
  id: string;
  code: string;
  name: string;
  active: boolean;
  sort_order: number;
  created_at: string;
  updated_at: string;
};

export type ProductRow = {
  id: string;
  sku: string;
  name: string;
  product_type: ProductType;
  category: string | null;
  unit: string;
  track_stock: boolean;
  commissionable: boolean;
  promo_eligible: boolean;
  default_min_stock: string;
  active: boolean;
  notes: string | null;
  created_at: string;
  updated_at: string;
};

export type KitComponentRow = {
  id: string;
  kit_product_id: string;
  component_product_id: string;
  quantity: string;
  created_at: string;
};

export type PriceConditionRow = {
  id: string;
  code: string;
  name: string;
  rule_type: PriceRuleType;
  payment_method_id: string | null;
  min_units: string | null;
  discount_percent: string | null;
  priority: number;
  combinable: boolean;
  active: boolean;
  created_at: string;
  updated_at: string;
};

export type ProductPriceRow = {
  id: string;
  product_id: string;
  price_condition_id: string;
  amount: string;
  valid_from: string;
  valid_until: string | null;
  active: boolean;
  created_at: string;
  created_by: string | null;
};

export type CustomerRow = {
  id: string;
  dni: string | null;
  full_name: string;
  whatsapp: string | null;
  email: string | null;
  created_at: string;
  created_by: string | null;
  origin_location_id: string | null;
  active: boolean;
  notes: string | null;
};

export type DoctorRow = {
  id: string;
  code: string;
  full_name: string;
  commission_percent: string;
  active: boolean;
  created_at: string;
  updated_at: string;
};

export type SaleRow = {
  id: string;
  sale_number: string;
  sold_at: string;
  location_id: string;
  sales_channel_id: string;
  seller_id: string | null;
  customer_id: string | null;
  doctor_id: string | null;
  payment_method_id: string;
  applied_price_condition_id: string | null;
  subtotal: string;
  discount_total: string;
  total: string;
  commission_total: string;
  status: SaleStatus;
  external_source: string | null;
  external_order_id: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
  is_free_sale: boolean;
  free_sale_reason: FreeSaleReason | null;
  free_sale_notes: string | null;
  stock_skipped: boolean;
};

export type SaleItemRow = {
  id: string;
  sale_id: string;
  product_id: string;
  quantity: string;
  list_unit_price: string;
  sale_unit_price: string;
  line_list_total: string;
  line_discount: string;
  line_total: string;
  applied_price_condition_id: string | null;
  commissionable: boolean;
  applied_promotion_id: string | null;
  promotion_discount: string;
  created_at: string;
};

export type PromotionRow = {
  id: string;
  code: string;
  name: string;
  type: PromotionType;
  discount_percent: string | null;
  group_size: number;
  priority: number;
  stackable: boolean;
  active: boolean;
  valid_from: string;
  valid_until: string | null;
  notes: string | null;
  created_at: string;
  created_by: string | null;
};

export type PromotionProductRow = {
  id: string;
  promotion_id: string;
  product_id: string;
  created_at: string;
};

export type InventoryBalanceRow = {
  location_id: string;
  product_id: string;
  quantity: string;
  min_stock_override: string | null;
  updated_at: string;
};

export type StockMovementRow = {
  id: string;
  occurred_at: string;
  location_id: string;
  product_id: string;
  movement_type: StockMovementType;
  quantity_delta: string;
  sale_id: string | null;
  transfer_id: string | null;
  reference: string | null;
  reason: StockAdjustmentReason | null;
  notes: string | null;
  created_by: string | null;
  created_at: string;
};

export type StockTransferRow = {
  id: string;
  transfer_number: string;
  from_location_id: string;
  to_location_id: string;
  status: StockTransferStatus;
  notes: string | null;
  created_by: string;
  created_at: string;
};

export type StockTransferItemRow = {
  id: string;
  transfer_id: string;
  product_id: string;
  quantity: string;
};

export type AuditLogRow = {
  id: string;
  user_id: string | null;
  action: string;
  entity_type: string;
  entity_id: string | null;
  metadata: Record<string, unknown>;
  created_at: string;
};

export type AppSettingsRow = {
  id: number;
  business_name: string;
  currency: string;
  timezone: string;
  allow_negative_stock: boolean;
  allow_transfer_overdraft: boolean;
  default_doctor_commission: string;
  low_stock_enabled: boolean;
  updated_at: string;
  updated_by: string | null;
};

export type KitAvailabilityRow = {
  kit_product_id: string;
  kit_sku: string;
  kit_name: string;
  location_id: string;
  location_code: string;
  buildable_qty: number;
};

export type ProductStockStatusRow = {
  product_id: string;
  sku: string;
  name: string;
  category: string | null;
  location_id: string;
  location_code: string;
  quantity: string;
  min_stock: string;
  status: "ok" | "bajo" | "sin_stock";
};

// ---------------------------------------------------------------------------
// RPC input/output
// ---------------------------------------------------------------------------

export type PricingItemInput = {
  product_id: string;
  quantity: number;
};

export type PricingLine = {
  product_id: string;
  sku: string;
  name: string;
  quantity: number;
  list_unit_price: number;
  sale_unit_price: number;
  line_list_total: number;
  line_discount: number;
  line_total: number;
  commissionable: boolean;
  applied_price_condition_id: string | null;
  applied_promotion_id?: string | null;
  promotion_discount?: number;
};

export type PricingQuoteResult =
  | {
      ok: true;
      error_message: null;
      applied_price_condition_id: string | null;
      applied_price_condition_code: string | null;
      applied_price_condition_name: string | null;
      explanation: string;
      subtotal: number;
      discount_total: number;
      total: number;
      lines: PricingLine[];
    }
  | { ok: false; error_message: string };

export type CreateSaleResult = {
  sale_id: string;
  sale_number: string;
  total: number;
  subtotal: number;
  discount_total: number;
  commission_total: number;
  applied_price_condition_name: string | null;
  explanation: string;
  is_free_sale?: boolean;
  stock_skipped?: boolean;
  lines: PricingLine[];
};

export type DashboardReport = {
  kpis: {
    sales_count: number;
    revenue: number;
    avg_ticket: number;
    units_sold: number;
    web_sales_count: number;
    commission_total: number;
  };
  revenue_by_day: { day: string; revenue: number }[];
  sales_by_location: { location: string; revenue: number; count: number }[];
  sales_by_channel: { channel: string; revenue: number; count: number }[];
  revenue_by_payment_method: { payment_method: string; revenue: number }[];
  top_products_by_units: { product: string; units: number }[];
  top_products_by_revenue: { product: string; revenue: number }[];
  commission_by_doctor: {
    doctor_id?: string;
    doctor: string;
    sales_count: number;
    commissionable_revenue: number;
    commission: number;
  }[];
  critical_stock_count: number;
};

export type ProductRevenueRow = {
  product_id: string;
  sku: string;
  name: string;
  product_type: ProductType;
  units: number;
  revenue: number;
  discount_total: number;
};

export type ProductRevenueReport = { rows: ProductRevenueRow[] };

export type DoctorSalesDetail = {
  doctor: { id: string; full_name: string; code: string };
  summary: { sales_count: number; commissionable_revenue: number; commission_total: number };
  products: { product_id: string; name: string; units: number; revenue: number }[];
  sales: {
    id: string;
    sale_number: string;
    sold_at: string;
    total: number;
    commission_total: number;
    location: string;
  }[];
};

// ---------------------------------------------------------------------------
// Shape que espera @supabase/supabase-js. IMPORTANTE: cada tabla se escribe
// como un literal plano (no vía un tipo genérico compartido tipo `Table<...>`)
// porque el parser de select-strings de postgrest-js no resuelve bien tipos
// construidos a partir de alias genéricos — con literales planos, igual que
// los que emite `supabase gen types`, funciona correctamente.
// ---------------------------------------------------------------------------

export type Database = {
  public: {
    Tables: {
      profiles: {
        Row: ProfileRow;
        Insert: { id: string } & Partial<ProfileRow>;
        Update: Partial<ProfileRow>;
        Relationships: [];
      };
      profile_locations: {
        Row: ProfileLocationRow;
        Insert: { profile_id: string; location_id: string } & Partial<ProfileLocationRow>;
        Update: Partial<ProfileLocationRow>;
        Relationships: [];
      };
      stock_locations: {
        Row: StockLocationRow;
        Insert: { code: string; short_code: string; name: string } & Partial<StockLocationRow>;
        Update: Partial<StockLocationRow>;
        Relationships: [];
      };
      sales_channels: {
        Row: SalesChannelRow;
        Insert: { code: string; name: string } & Partial<SalesChannelRow>;
        Update: Partial<SalesChannelRow>;
        Relationships: [];
      };
      payment_methods: {
        Row: PaymentMethodRow;
        Insert: { code: string; name: string } & Partial<PaymentMethodRow>;
        Update: Partial<PaymentMethodRow>;
        Relationships: [];
      };
      products: {
        Row: ProductRow;
        Insert: { sku: string; name: string } & Partial<ProductRow>;
        Update: Partial<ProductRow>;
        Relationships: [];
      };
      kit_components: {
        Row: KitComponentRow;
        Insert: { kit_product_id: string; component_product_id: string; quantity: string } &
          Partial<KitComponentRow>;
        Update: Partial<KitComponentRow>;
        Relationships: [];
      };
      price_conditions: {
        Row: PriceConditionRow;
        Insert: { code: string; name: string; rule_type: PriceRuleType; priority: number } &
          Partial<PriceConditionRow>;
        Update: Partial<PriceConditionRow>;
        Relationships: [];
      };
      product_prices: {
        Row: ProductPriceRow;
        Insert: { product_id: string; price_condition_id: string; amount: string } &
          Partial<ProductPriceRow>;
        Update: Partial<ProductPriceRow>;
        Relationships: [];
      };
      promotions: {
        Row: PromotionRow;
        Insert: { code: string; name: string; type: PromotionType } & Partial<PromotionRow>;
        Update: Partial<PromotionRow>;
        Relationships: [];
      };
      // La composición (qué productos) se edita exclusivamente vía la RPC
      // set_promotion_products — ver comentario en la migración. Insert/delete
      // directo queda disponible por RLS pero la UI de admin nunca lo usa
      // (evita el edge case de conteo a mitad de transacción).
      promotion_products: {
        Row: PromotionProductRow;
        Insert: { promotion_id: string; product_id: string } & Partial<PromotionProductRow>;
        Update: Partial<PromotionProductRow>;
        Relationships: [];
      };
      customers: {
        Row: CustomerRow;
        Insert: { full_name: string } & Partial<CustomerRow>;
        Update: Partial<CustomerRow>;
        Relationships: [];
      };
      doctors: {
        Row: DoctorRow;
        Insert: { code: string; full_name: string } & Partial<DoctorRow>;
        Update: Partial<DoctorRow>;
        Relationships: [];
      };
      // Las siguientes tablas se escriben EXCLUSIVAMENTE vía RPC (create_sale,
      // cancel_sale, transfer_stock, adjust_stock): sin insert/update directo.
      sales: { Row: SaleRow; Insert: never; Update: never; Relationships: [] };
      sale_items: { Row: SaleItemRow; Insert: never; Update: never; Relationships: [] };
      inventory_balances: { Row: InventoryBalanceRow; Insert: never; Update: never; Relationships: [] };
      stock_movements: { Row: StockMovementRow; Insert: never; Update: never; Relationships: [] };
      stock_transfers: { Row: StockTransferRow; Insert: never; Update: never; Relationships: [] };
      stock_transfer_items: {
        Row: StockTransferItemRow;
        Insert: never;
        Update: never;
        Relationships: [];
      };
      // Insert real solo desde código server-side con la service role key (ver
      // app/(app)/admin/usuarios/actions.ts) — no hay policy de INSERT para
      // `authenticated`, así que un insert del cliente normal sigue fallando
      // en RLS pase lo que pase este tipo. El resto de las escrituras vienen
      // de los triggers/RPCs (SECURITY DEFINER, bypassean RLS igual).
      audit_logs: {
        Row: AuditLogRow;
        Insert: { action: string; entity_type: string } & Partial<AuditLogRow>;
        Update: never;
        Relationships: [];
      };
      app_settings: {
        Row: AppSettingsRow;
        Insert: never;
        Update: Partial<AppSettingsRow>;
        Relationships: [];
      };
    };
    Views: {
      kit_availability: { Row: KitAvailabilityRow; Relationships: [] };
      product_stock_status: { Row: ProductStockStatusRow; Relationships: [] };
    };
    Functions: {
      quote_sale: {
        Args: {
          p_items: PricingItemInput[];
          p_payment_method_id: string;
          p_sold_at?: string;
          p_is_free_sale?: boolean;
        };
        Returns: PricingQuoteResult;
      };
      create_sale: {
        Args: {
          p_items: PricingItemInput[];
          p_location_id: string;
          p_sales_channel_id: string;
          p_payment_method_id: string;
          p_customer_id?: string | null;
          p_doctor_id?: string | null;
          p_notes?: string | null;
          p_external_source?: string | null;
          p_external_order_id?: string | null;
          p_sold_at?: string;
          p_is_free_sale?: boolean;
          p_free_sale_reason?: FreeSaleReason | null;
          p_free_sale_notes?: string | null;
          p_skip_stock_movement?: boolean;
        };
        Returns: CreateSaleResult;
      };
      cancel_sale: {
        Args: { p_sale_id: string; p_reason: string };
        Returns: { sale_id: string; status: "cancelled" };
      };
      transfer_stock: {
        Args: {
          p_from_location_id: string;
          p_to_location_id: string;
          p_items: { product_id: string; quantity: number }[];
          p_notes?: string | null;
        };
        Returns: { transfer_id: string; transfer_number: string };
      };
      adjust_stock: {
        Args: {
          p_location_id: string;
          p_product_id: string;
          p_quantity_delta: number;
          p_reason: StockAdjustmentReason;
          p_notes?: string | null;
        };
        Returns: { movement_id: string; stock_before: number; stock_after: number };
      };
      set_stock: {
        Args: {
          p_location_id: string;
          p_product_id: string;
          p_new_quantity: number;
          p_reason: StockAdjustmentReason;
          p_notes?: string | null;
        };
        Returns: { movement_id: string | null; stock_before: number; stock_after: number; changed: boolean };
      };
      deactivate_customer: {
        Args: { p_customer_id: string };
        Returns: { customer_id: string; active: boolean };
      };
      set_promotion_products: {
        Args: { p_promotion_id: string; p_product_ids: string[] };
        Returns: { promotion_id: string; product_count: number };
      };
      set_product_price: {
        Args: {
          p_product_id: string;
          p_price_condition_id: string;
          p_amount: number;
          p_valid_from?: string;
        };
        Returns: ProductPriceRow;
      };
      dashboard_report: {
        Args: {
          p_from: string;
          p_to: string;
          p_location_id?: string | null;
          p_sales_channel_id?: string | null;
        };
        Returns: DashboardReport;
      };
      product_revenue_report: {
        Args: {
          p_from: string;
          p_to: string;
          p_location_id?: string | null;
          p_sales_channel_id?: string | null;
        };
        Returns: ProductRevenueReport;
      };
      doctor_sales_detail: {
        Args: { p_doctor_id: string; p_from: string; p_to: string; p_location_id?: string | null };
        Returns: DoctorSalesDetail;
      };
      create_web_order: {
        Args: {
          p_items: PricingItemInput[];
          p_location_id: string;
          p_payment_method_id: string;
          p_external_source: string;
          p_external_order_id: string;
          p_customer_id?: string | null;
          p_doctor_id?: string | null;
          p_notes?: string | null;
          p_sold_at?: string;
        };
        Returns: CreateSaleResult;
      };
    };
    Enums: {
      app_role: AppRole;
      stock_location_type: StockLocationType;
      product_type: ProductType;
      price_rule_type: PriceRuleType;
      sale_status: SaleStatus;
      stock_movement_type: StockMovementType;
      stock_transfer_status: StockTransferStatus;
      stock_adjustment_reason: StockAdjustmentReason;
    };
  };
};
