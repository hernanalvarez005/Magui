"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { CheckCircle2, ClipboardCopy, Search, WifiOff } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { EmptyState } from "@/components/shared/empty-state";
import { ProductCard, type ProductCardData } from "@/components/sales/product-card";
import { NewSaleCart } from "@/components/sales/new-sale-cart";
import type { CustomerOption } from "@/components/sales/customer-picker-dialog";
import { createClient } from "@/lib/supabase/client";
import { shouldShowTransferAlias } from "@/lib/sales/payment-account-alias";
import { formatCurrency } from "@/lib/utils";
import { newSaleSchema } from "@/lib/validation/sale";
import {
  computeRequiresPaymentAccountNow,
  resolveFulfillmentLocationId,
  resolveFulfillmentType,
  type FulfillmentChoice,
} from "@/lib/sales/web-fulfillment";
import type { CreateSaleResult, FreeSaleReason, PricingQuoteResult, SalePaymentStatus } from "@/types/database";

interface LocationOption {
  id: string;
  code: string;
  name: string;
}
interface ChannelOption {
  id: string;
  code: string;
  name: string;
}
interface PaymentMethodOption {
  id: string;
  code: string;
  name: string;
}
interface PaymentAccountOption {
  id: string;
  code: string;
  name: string;
  alias: string | null;
}

// Formas de pago que la cuenta de ingreso vuelve obligatoria y que
// disparan facturación pendiente — el backend (fn_create_sale_core) vuelve
// a decidir esto de forma independiente, esto es solo para mostrar/ocultar
// el selector en el momento justo.
const ACCOUNT_REQUIRED_CODES = ["TRANSFER", "CARD_1", "CARD_3"];
interface DoctorOption {
  id: string;
  code: string;
  full_name: string;
}
interface ProductOption {
  id: string;
  sku: string;
  name: string;
  product_type: string;
  category: string | null;
  track_stock: boolean;
  image_url: string | null;
  kitContents: string[] | null;
}
interface PromotionOption {
  id: string;
  name: string;
  type: "THREE_FOR_TWO" | "DUO_PERCENT" | "KIT_PERCENT" | "QUANTITY_DISCOUNT";
  discount_percent: string | null;
  group_size: number;
  minimum_quantity: number | null;
}

/**
 * Nueva Venta — pantalla principal (rediseño UX "carrito unificado").
 * Se concentra en: elegir canal/sucursal, buscar y agregar productos.
 * Todo lo demás (cliente, doctora, observaciones, venta sin costo, carga
 * histórica, medio de pago, cuenta/alias, resumen y confirmación) vive
 * dentro de NewSaleCart — el carrito es el checkout.
 *
 * Ajuste UX (revisión posterior al rediseño original): el carrito NUNCA se
 * abre solo, ni siquiera con el primer producto — agregar solo actualiza
 * cart/cartCount/quote y el botón flotante ("Carrito · N · $X"), sin tocar
 * cartOpen. El drawer/sheet se abre EXCLUSIVAMENTE por click explícito de la
 * vendedora en ese botón. Catálogo sin obstrucciones mientras arma el
 * pedido; abre el carrito recién cuando quiere cerrar la venta.
 *
 * Única fuente de estado (sección 26 del pedido): todo el estado de la
 * operación vive acá, en este componente — NewSaleCart es puramente de
 * presentación, no duplica ningún campo.
 */
export function NewSaleClient({
  seller,
  locations,
  channels,
  paymentMethods,
  paymentAccounts,
  doctors,
  products,
  promotions,
  isAdmin,
}: {
  seller: { id: string; fullName: string };
  locations: LocationOption[];
  channels: ChannelOption[];
  paymentMethods: PaymentMethodOption[];
  paymentAccounts: PaymentAccountOption[];
  doctors: DoctorOption[];
  products: ProductOption[];
  promotions: PromotionOption[];
  isAdmin: boolean;
}) {
  const supabase = useMemo(() => createClient(), []);

  const branchChannel = channels.find((c) => c.code === "BRANCH") ?? channels[0];
  const [channelId, setChannelId] = useState(branchChannel?.id ?? "");
  const [locationId, setLocationId] = useState(locations[0]?.id ?? "");
  const [paymentMethodId, setPaymentMethodId] = useState(paymentMethods[0]?.id ?? "");
  const [paymentAccountId, setPaymentAccountId] = useState("");

  // Forma de entrega (BLOQUE C, circuito Ventas Web) — exclusiva del canal
  // Web. Cada opción resuelve directo a (fulfillment_type, sede física):
  // nunca se vuelve a pedir la sede por separado, para no dar lugar a una
  // combinación inconsistente que el backend termine rechazando igual.
  // Reglas puras en lib/sales/web-fulfillment.ts (testeadas ahí).
  const sed25Location = locations.find((l) => l.code === "SED-25");
  const sed37Location = locations.find((l) => l.code === "SED-37");
  const depositoLocation = locations.find((l) => l.code === "DEP");
  const [fulfillmentChoice, setFulfillmentChoice] = useState<FulfillmentChoice>("");
  const [paymentStatus, setPaymentStatus] = useState<SalePaymentStatus>("PAID");
  const fulfillmentType = resolveFulfillmentType(fulfillmentChoice);
  const fulfillmentLocationId = resolveFulfillmentLocationId(fulfillmentChoice, locations);
  const [cart, setCart] = useState<Record<string, number>>({});
  const [search, setSearch] = useState("");
  const [customer, setCustomer] = useState<CustomerOption | null>(null);
  const [doctorId, setDoctorId] = useState<string>("none");
  const [notes, setNotes] = useState("");
  const [externalSource, setExternalSource] = useState("");
  const [externalOrderId, setExternalOrderId] = useState("");
  const [isFreeSale, setIsFreeSale] = useState(false);
  const [freeSaleReason, setFreeSaleReason] = useState<FreeSaleReason | "">("");
  const [freeSaleNotes, setFreeSaleNotes] = useState("");

  // Precio manual por línea (exclusivo de admin): se guarda como texto tal
  // cual lo tipea (permite dejarlo vacío/a medio escribir), se convierte a
  // número recién al armar cartItems. El backend es la autoridad real —
  // create_sale() vuelve a validar que quien llama sea admin, esto es solo
  // para no mandar un campo que la mayoría de los usuarios ni ve.
  const [manualPrices, setManualPrices] = useState<Record<string, string>>({});

  // Carga histórica (admin): fecha pasada + opción de no descontar del stock
  // real, para completar ventas que ya pasaron y cuyo stock ya no refleja.
  const [isHistorical, setIsHistorical] = useState(false);
  const [historicalSoldAt, setHistoricalSoldAt] = useState("");
  const [skipStockMovement, setSkipStockMovement] = useState(false);

  const [stock, setStock] = useState<Record<string, number>>({});
  const [lowStock, setLowStock] = useState<Record<string, boolean>>({});
  const [kitAvailability, setKitAvailability] = useState<Record<string, number>>({});

  const [quote, setQuote] = useState<PricingQuoteResult | null>(null);
  const [quoting, setQuoting] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [receipt, setReceipt] = useState<CreateSaleResult | null>(null);
  const [online, setOnline] = useState(() => (typeof navigator === "undefined" ? true : navigator.onLine));
  // Ajuste UX: el carrito NUNCA se abre solo — únicamente por acción
  // explícita de la vendedora (botón "Ver carrito"/"Carrito"). Agregar
  // productos actualiza cart/cartCount/quote sin tocar este estado.
  const [cartOpen, setCartOpen] = useState(false);

  const selectedChannel = channels.find((c) => c.id === channelId);
  const isWeb = selectedChannel?.code === "WEB";

  useEffect(() => {
    const goOnline = () => setOnline(true);
    const goOffline = () => setOnline(false);
    window.addEventListener("online", goOnline);
    window.addEventListener("offline", goOffline);
    return () => {
      window.removeEventListener("online", goOnline);
      window.removeEventListener("offline", goOffline);
    };
  }, []);

  // Stock de la sede seleccionada (productos trackeables + disponibilidad de
  // kits). Canal Web: usa web_admin_stock_availability (RPC security
  // definer, solo admin) en vez de product_stock_status/kit_availability —
  // esas vistas dependen del RLS del usuario que consulta, y un admin sin
  // esa sede en profile_locations vería stock vacío ahí aunque la venta se
  // cree correctamente (20260201000057 ya se lo permite). La RPC además
  // devuelve disponible = físico - reservado, no el físico crudo (sección
  // 4 del pedido: "el stock se reserva ahora" tiene que verse reflejado acá
  // mismo). Venta presencial: sin cambios, sigue usando las vistas de
  // siempre — RLS de vendedores/ventas presenciales no se toca.
  useEffect(() => {
    if (!locationId) return;
    let cancelled = false;

    async function loadStock() {
      const nextStock: Record<string, number> = {};
      const nextLow: Record<string, boolean> = {};
      const nextKits: Record<string, number> = {};

      if (isWeb) {
        const { data: rows } = await supabase.rpc("web_admin_stock_availability", {
          p_location_id: locationId,
        });
        if (cancelled) return;
        for (const row of rows ?? []) {
          const available = Number(row.available);
          if (row.is_kit) {
            nextKits[row.product_id] = available;
          } else {
            nextStock[row.product_id] = available;
            nextLow[row.product_id] = row.status === "bajo";
          }
        }
      } else {
        const [{ data: stockRows }, { data: kitRows }] = await Promise.all([
          supabase
            .from("product_stock_status")
            .select("product_id, quantity, status")
            .eq("location_id", locationId),
          supabase.from("kit_availability").select("kit_product_id, buildable_qty").eq("location_id", locationId),
        ]);
        if (cancelled) return;
        for (const row of stockRows ?? []) {
          nextStock[row.product_id] = Number(row.quantity);
          nextLow[row.product_id] = row.status === "bajo";
        }
        for (const row of kitRows ?? []) {
          nextKits[row.kit_product_id] = row.buildable_qty;
        }
      }

      setStock(nextStock);
      setLowStock(nextLow);
      setKitAvailability(nextKits);
    }

    loadStock();
    return () => {
      cancelled = true;
    };
  }, [locationId, supabase, isWeb]);

  // Cuenta de ingreso: obligatoria solo para transferencia/1 pago/3 cuotas,
  // nunca para efectivo ni venta sin costo. El backend (fn_create_sale_core)
  // vuelve a decidir esto de forma independiente — esto es solo para
  // mostrar/pedir el campo en el momento justo, nunca la fuente de verdad.
  //
  // requiresBilling: sigue exigiendo cliente con DNI (factura pendiente),
  // sin excepción. requiresPaymentAccountNow es más angosto — un pedido Web
  // PENDIENTE de cobro puede confirmarse sin la cuenta todavía (no se sabe
  // en qué cuenta va a entrar un cobro que no pasó), se completa después al
  // cobrar. No confundir "factura pendiente" con "cobro pendiente" (sección
  // 17 del pedido original) — son ejes distintos, nunca se mezclan.
  const selectedPaymentMethod = paymentMethods.find((pm) => pm.id === paymentMethodId);
  const requiresBilling = !isFreeSale && ACCOUNT_REQUIRED_CODES.includes(selectedPaymentMethod?.code ?? "");
  const requiresPaymentAccountNow = computeRequiresPaymentAccountNow({ requiresBilling, isWeb, paymentStatus });

  // Alias para transferencia: a propósito NO es lo mismo que
  // requiresPaymentAccount (eso también incluye 1 pago/3 cuotas) — el alias
  // solo tiene sentido cuando el medio es Transferencia en sí, y únicamente
  // si la cuenta elegida tiene alias cargado. Genérico por diseño: no hay
  // ningún "if Mercado Pago" hardcodeado, cualquier cuenta con alias lo
  // muestra igual.
  const selectedPaymentAccount = paymentAccounts.find((pa) => pa.id === paymentAccountId);
  const showAlias = shouldShowTransferAlias({
    isFreeSale,
    paymentMethodCode: selectedPaymentMethod?.code,
    account: selectedPaymentAccount,
  });

  function handlePaymentMethodChange(id: string) {
    setPaymentMethodId(id);
    const code = paymentMethods.find((pm) => pm.id === id)?.code ?? "";
    if (!ACCOUNT_REQUIRED_CODES.includes(code)) setPaymentAccountId("");
  }

  // Cambiar de canal resetea la forma de entrega (nunca queda una sede
  // heredada de una selección Web anterior) y, al salir de Web, apaga venta
  // sin costo/carga histórica si habían quedado activadas — el backend las
  // rechaza igual combinadas con fulfillment_type, esto solo evita mostrar
  // un formulario que va a fallar al confirmar.
  function handleChannelChange(id: string) {
    setChannelId(id);
    setFulfillmentChoice("");
    setPaymentStatus("PAID");
    const code = channels.find((c) => c.id === id)?.code;
    if (code !== "WEB") {
      setIsFreeSale(false);
      setIsHistorical(false);
    }
  }

  function handleFulfillmentChoiceChange(choice: "PICKUP_25" | "PICKUP_37" | "SHIPPING") {
    setFulfillmentChoice(choice);
    const id = resolveFulfillmentLocationId(choice, locations);
    if (id) setLocationId(id);
  }

  const cartItems = useMemo(
    () =>
      Object.entries(cart)
        .filter(([, qty]) => qty > 0)
        .map(([product_id, quantity]) => {
          const raw = isAdmin ? manualPrices[product_id]?.trim() : undefined;
          const manualPrice = raw ? Number(raw) : NaN;
          return {
            product_id,
            quantity,
            ...(raw && !Number.isNaN(manualPrice) && manualPrice > 0 ? { manual_price: manualPrice } : {}),
          };
        }),
    [cart, manualPrices, isAdmin]
  );
  const cartCount = cartItems.reduce((acc, i) => acc + i.quantity, 0);

  // Recalcula el precio en el servidor (RPC de solo lectura) cada vez que cambia el carrito
  // o el medio de pago. Esto es una ESTIMACIÓN: create_sale() vuelve a calcular todo al confirmar.
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);

    debounceRef.current = setTimeout(async () => {
      if (cartItems.length === 0 || !paymentMethodId) {
        setQuote(null);
        setQuoting(false);
        return;
      }

      setQuoting(true);
      const { data, error } = await supabase.rpc("quote_sale", {
        p_items: cartItems,
        p_payment_method_id: paymentMethodId,
        p_is_free_sale: isFreeSale,
      });
      if (error) {
        setQuote({ ok: false, error_message: humanizeSaleError(error.message) });
      } else {
        setQuote(data as PricingQuoteResult);
      }
      setQuoting(false);
    }, 300);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(cartItems), paymentMethodId, isFreeSale]);

  function setQuantity(productId: string, quantity: number) {
    // Feedback breve (sección 8 del pedido "no abrir carrito automáticamente")
    // — SOLO en la transición 0 -> N de ESE producto puntual (recién entra al
    // carrito), nunca en cada click de +/- posterior: evita un toast por cada
    // unidad al ir subiendo la cantidad desde la card.
    const wasEmpty = !cart[productId];
    if (wasEmpty && quantity > 0) {
      const product = products.find((p) => p.id === productId);
      toast.success(product ? `${product.name} agregado al carrito` : "Agregado al carrito", { duration: 1500 });
    }

    setCart((prev) => {
      const next = { ...prev };
      if (quantity <= 0) {
        delete next[productId];
      } else {
        next[productId] = quantity;
      }
      return next;
    });
    if (quantity <= 0) {
      setManualPrices((prev) => {
        if (!(productId in prev)) return prev;
        const next = { ...prev };
        delete next[productId];
        return next;
      });
    }
  }

  function setManualPrice(productId: string, value: string) {
    setManualPrices((prev) => ({ ...prev, [productId]: value }));
  }

  const filteredProducts = products.filter((p) =>
    search.trim().length === 0
      ? true
      : p.name.toLowerCase().includes(search.toLowerCase()) || p.sku.toLowerCase().includes(search.toLowerCase())
  );

  function productCardData(p: ProductOption): ProductCardData {
    const isKit = p.product_type === "kit" || !p.track_stock;
    const stockQty = isKit ? (kitAvailability[p.id] ?? 0) : (stock[p.id] ?? null);
    const line = quote?.ok ? quote.lines.find((l) => l.product_id === p.id) : undefined;
    return {
      id: p.id,
      sku: p.sku,
      name: p.name,
      category: p.category,
      isKit,
      stock: stockQty,
      lowStock: lowStock[p.id] ?? false,
      unitPrice: line?.sale_unit_price ?? null,
      imageUrl: p.image_url,
      kitContents: p.kitContents,
    };
  }

  async function handleConfirm() {
    if (isHistorical && !historicalSoldAt) {
      toast.error("Elegí la fecha de la venta histórica.");
      return;
    }

    if (isWeb && !fulfillmentType) {
      toast.error("Elegí la forma de entrega (retiro en sede o envío por correo).");
      return;
    }

    if (isWeb && fulfillmentType && !fulfillmentLocationId) {
      toast.error("No tenés acceso a la sede necesaria para esta forma de entrega. Pedile a un administrador que te la habilite.");
      return;
    }

    if (requiresPaymentAccountNow && !paymentAccountId) {
      toast.error("Elegí la cuenta donde ingresó el dinero.");
      return;
    }

    if (requiresBilling && !customer?.dni) {
      toast.error("Esta operación se puede facturar — necesita un cliente identificado con nombre y DNI.");
      return;
    }

    const payload = {
      items: cartItems,
      location_id: locationId,
      sales_channel_id: channelId,
      payment_method_id: paymentMethodId,
      customer_id: customer?.id ?? null,
      doctor_id: doctorId === "none" ? null : doctorId,
      notes: notes.trim() || null,
      is_free_sale: isFreeSale,
      free_sale_reason: isFreeSale ? freeSaleReason || null : null,
      free_sale_notes: isFreeSale ? freeSaleNotes.trim() || null : null,
      sold_at: isHistorical && historicalSoldAt ? `${historicalSoldAt}:00-03:00` : null,
      skip_stock_movement: isHistorical && skipStockMovement,
    };
    const parsed = newSaleSchema.safeParse(payload);
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Revisá los datos de la venta.");
      return;
    }

    setConfirming(true);
    const { data, error } = await supabase.rpc("create_sale", {
      p_items: parsed.data.items,
      p_location_id: parsed.data.location_id,
      p_sales_channel_id: parsed.data.sales_channel_id,
      p_payment_method_id: parsed.data.payment_method_id,
      p_customer_id: parsed.data.customer_id,
      p_doctor_id: parsed.data.doctor_id,
      p_notes: parsed.data.notes,
      p_external_source: isWeb ? externalSource.trim() || null : null,
      p_external_order_id: isWeb ? externalOrderId.trim() || null : null,
      p_is_free_sale: parsed.data.is_free_sale,
      p_free_sale_reason: parsed.data.free_sale_reason,
      p_free_sale_notes: parsed.data.free_sale_notes,
      ...(parsed.data.sold_at ? { p_sold_at: parsed.data.sold_at } : {}),
      p_skip_stock_movement: parsed.data.skip_stock_movement,
      p_payment_account_id: requiresBilling ? paymentAccountId.trim() || null : null,
      p_fulfillment_type: isWeb ? fulfillmentType : null,
      p_payment_status: isWeb ? paymentStatus : null,
    });
    setConfirming(false);

    if (error) {
      toast.error(humanizeSaleError(error.message));
      return;
    }

    setReceipt(data as CreateSaleResult);
    setCartOpen(false);
  }

  function resetForNewSale() {
    setCart({});
    setCustomer(null);
    setPaymentAccountId("");
    setDoctorId("none");
    setNotes("");
    setQuote(null);
    setReceipt(null);
    setIsFreeSale(false);
    setFreeSaleReason("");
    setFreeSaleNotes("");
    setIsHistorical(false);
    setHistoricalSoldAt("");
    setFulfillmentChoice("");
    setPaymentStatus("PAID");
    setSkipStockMovement(false);
    setManualPrices({});
  }

  if (receipt) {
    return <ReceiptView receipt={receipt} onNewSale={resetForNewSale} locations={locations} />;
  }

  return (
    <div className="flex flex-col gap-4 pb-40 md:pb-8">
      {/*
        pb-40 en mobile: el botón flotante del carrito (fixed, bottom-20,
        alto xl = h-16) ocupa desde los 80px hasta los ~144px del piso de la
        pantalla. Sin este padding, el final del catálogo quedaba tapado por
        ese botón. En md: el carrito pasa a una caja angosta en la esquina
        (md:right-6 md:w-96), así que alcanza con menos aire.
      */}
      <div className="sticky top-14 z-20 flex flex-col gap-3 border-b border-border bg-background/95 px-4 pb-3 pt-3 backdrop-blur md:top-16 md:px-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-lg font-semibold">Nueva venta</h1>
            <p className="text-xs text-muted-foreground">{seller.fullName}</p>
          </div>
          {!online ? (
            <Badge variant="destructive" className="gap-1">
              <WifiOff className="size-3" /> Sin conexión
            </Badge>
          ) : null}
        </div>

        <div className="grid grid-cols-2 gap-2">
          <div className="flex flex-col gap-1">
            <Label className="text-xs text-muted-foreground">Canal</Label>
            <Select value={channelId} onValueChange={handleChannelChange}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {channels.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          {isWeb ? (
            // Web: la sede se resuelve DIRECTO de la forma de entrega — nunca
            // se vuelve a pedir por separado (sección 25 del pedido).
            <div className="flex flex-col gap-1">
              <Label className="text-xs text-muted-foreground">Forma de entrega</Label>
              <Select
                value={fulfillmentChoice}
                onValueChange={(v) => handleFulfillmentChoiceChange(v as "PICKUP_25" | "PICKUP_37" | "SHIPPING")}
              >
                <SelectTrigger>
                  <SelectValue placeholder="Elegí una opción" />
                </SelectTrigger>
                <SelectContent>
                  {sed25Location ? <SelectItem value="PICKUP_25">Retiro Sede 25</SelectItem> : null}
                  {sed37Location ? <SelectItem value="PICKUP_37">Retiro Sede 37</SelectItem> : null}
                  {depositoLocation ? <SelectItem value="SHIPPING">Envío por correo</SelectItem> : null}
                </SelectContent>
              </Select>
            </div>
          ) : (
            <div className="flex flex-col gap-1">
              <Label className="text-xs text-muted-foreground">Sucursal</Label>
              {locations.length <= 1 ? (
                // Una sola sede habilitada: se muestra fija, no se obliga a
                // elegir algo cuando no hay ninguna otra opción válida.
                <div className="flex h-9 items-center rounded-md border border-input bg-muted px-3 text-sm">
                  {locations[0]?.name ?? "—"}
                </div>
              ) : (
                <Select value={locationId} onValueChange={setLocationId}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {locations.map((l) => (
                      <SelectItem key={l.id} value={l.id}>
                        {l.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            </div>
          )}
        </div>

        {/* Efecto de stock — sección 4 del pedido: siempre visible apenas se
            elige la forma de entrega, nunca implícito. */}
        {isWeb && fulfillmentType ? (
          <p className="rounded-md bg-muted px-3 py-2 text-xs text-muted-foreground">
            {fulfillmentType === "PICKUP"
              ? "Retiro en sede: el stock se reserva ahora y se descuenta recién cuando se entregue el pedido."
              : "Envío por correo: el stock se descuenta de inmediato del Depósito."}
          </p>
        ) : null}

        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar producto…"
            className="pl-9"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
      </div>

      <div className="px-4 md:px-6">
        {filteredProducts.length === 0 ? (
          <EmptyState
            title="No encontramos productos que coincidan con tu búsqueda."
            className="mt-6"
          />
        ) : (
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
            {filteredProducts.map((p) => (
              <ProductCard
                key={p.id}
                product={productCardData(p)}
                quantity={cart[p.id] ?? 0}
                onChange={(qty) => setQuantity(p.id, qty)}
              />
            ))}
          </div>
        )}
      </div>

      <NewSaleCart
        open={cartOpen}
        onOpenChange={setCartOpen}
        cartCount={cartCount}
        cartItems={cartItems}
        products={products}
        promotions={promotions}
        quote={quote}
        quoting={quoting}
        onRemoveItem={(id) => setQuantity(id, 0)}
        isAdmin={isAdmin}
        manualPrices={manualPrices}
        onManualPriceChange={setManualPrice}
        onClearManualPrices={() => setManualPrices({})}
        customer={customer}
        onSelectCustomer={setCustomer}
        onClearCustomer={() => setCustomer(null)}
        doctors={doctors}
        doctorId={doctorId}
        onDoctorIdChange={setDoctorId}
        isWeb={isWeb}
        fulfillmentSelected={!isWeb || !!fulfillmentType}
        externalSource={externalSource}
        onExternalSourceChange={setExternalSource}
        externalOrderId={externalOrderId}
        onExternalOrderIdChange={setExternalOrderId}
        notes={notes}
        onNotesChange={setNotes}
        isFreeSale={isFreeSale}
        onIsFreeSaleChange={setIsFreeSale}
        freeSaleReason={freeSaleReason}
        onFreeSaleReasonChange={setFreeSaleReason}
        freeSaleNotes={freeSaleNotes}
        onFreeSaleNotesChange={setFreeSaleNotes}
        isAdminHistoricalAllowed={isAdmin}
        isHistorical={isHistorical}
        onIsHistoricalChange={setIsHistorical}
        historicalSoldAt={historicalSoldAt}
        onHistoricalSoldAtChange={setHistoricalSoldAt}
        skipStockMovement={skipStockMovement}
        onSkipStockMovementChange={setSkipStockMovement}
        paymentMethods={paymentMethods}
        paymentMethodId={paymentMethodId}
        onPaymentMethodChange={handlePaymentMethodChange}
        requiresBilling={requiresBilling}
        requiresPaymentAccount={requiresPaymentAccountNow}
        paymentAccounts={paymentAccounts}
        paymentAccountId={paymentAccountId}
        onPaymentAccountChange={setPaymentAccountId}
        showAlias={showAlias}
        paymentStatus={paymentStatus}
        onPaymentStatusChange={setPaymentStatus}
        online={online}
        confirming={confirming}
        onConfirm={handleConfirm}
      />
    </div>
  );
}

function ReceiptView({
  receipt,
  onNewSale,
  locations,
}: {
  receipt: CreateSaleResult;
  onNewSale: () => void;
  locations: LocationOption[];
}) {
  const pickupLocationName = receipt.pickup_location_id
    ? (locations.find((l) => l.id === receipt.pickup_location_id)?.name ?? null)
    : null;
  return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-5 px-4 py-10 text-center">
      <div className="flex size-16 items-center justify-center rounded-full bg-success/20">
        <CheckCircle2 className="size-9 text-success" />
      </div>
      <div>
        <h1 className="text-xl font-semibold">
          {receipt.is_free_sale ? "Entrega sin costo registrada" : "Venta registrada"}
        </h1>
        <p className="text-sm text-muted-foreground">{receipt.sale_number}</p>
        {receipt.stock_skipped ? (
          <p className="mt-1 text-xs text-warning-foreground">Carga histórica — no se descontó del stock real.</p>
        ) : null}
        {receipt.fulfillment_type ? (
          <div className="mt-2 flex flex-wrap items-center justify-center gap-1.5">
            <Badge variant="secondary" className="font-normal">
              {receipt.fulfillment_type === "PICKUP"
                ? `Retiro pendiente — ${pickupLocationName ?? "sede"}`
                : "Envío — descontado de Depósito"}
            </Badge>
            <Badge variant={receipt.payment_status === "PENDING" ? "destructive" : "success"} className="font-normal">
              {receipt.payment_status === "PENDING" ? "PENDIENTE DE COBRO" : "PAGADO"}
            </Badge>
          </div>
        ) : null}
      </div>

      <div className="w-full rounded-xl border border-border bg-card p-5 text-left shadow-sm">
        <div className="flex flex-col gap-1.5 text-sm">
          {receipt.lines.map((line, idx) => (
            <div key={`${line.product_id}-${idx}`} className="flex justify-between">
              <span>
                {line.quantity} × {line.name}
                {line.applied_promotion_id ? " · promo" : ""}
                {line.manual_price ? " · precio manual" : ""}
              </span>
              <span className="font-medium">{formatCurrency(line.line_total)}</span>
            </div>
          ))}
        </div>
        <Separator className="my-3" />
        {receipt.discount_total > 0 || (receipt.surcharge_total ?? 0) > 0 ? (
          <div className="flex justify-between text-sm text-muted-foreground">
            <span>{receipt.applied_price_condition_name ?? receipt.explanation}</span>
            {receipt.discount_total > 0 ? (
              <span>-{formatCurrency(receipt.discount_total)}</span>
            ) : (
              <span className="text-destructive">+{formatCurrency(receipt.surcharge_total ?? 0)}</span>
            )}
          </div>
        ) : null}
        <div className="mt-1 flex items-center justify-between">
          <span className="font-semibold">TOTAL</span>
          <span className="text-2xl font-bold">{formatCurrency(receipt.total)}</span>
        </div>
      </div>

      <div className="flex w-full flex-col gap-2">
        <Button size="lg" onClick={onNewSale}>
          Nueva venta
        </Button>
        <Button variant="outline" size="lg" asChild>
          <Link href={`/ventas/${receipt.sale_id}`}>Ver detalle</Link>
        </Button>
        <Button
          variant="ghost"
          size="lg"
          onClick={() => {
            const text = `${receipt.sale_number}\n${receipt.lines
              .map((l) => `${l.quantity}x ${l.name} — ${formatCurrency(l.line_total)}`)
              .join("\n")}\nTotal: ${formatCurrency(receipt.total)}`;
            navigator.clipboard.writeText(text);
            toast.success("Resumen copiado.");
          }}
        >
          <ClipboardCopy className="size-4" /> Copiar resumen
        </Button>
      </div>
    </div>
  );
}

function humanizeSaleError(message: string): string {
  // Los mensajes de create_sale() ya son legibles (RAISE EXCEPTION con texto en español).
  // Esto es un fallback por si llega algo técnico de Postgres/PostgREST.
  if (message.toLowerCase().includes("jwt") || message.toLowerCase().includes("auth")) {
    return "Tu sesión expiró. Volvé a ingresar.";
  }
  return message;
}
