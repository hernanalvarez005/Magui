-- =============================================================================
-- Maguirejuve · 18 · "Establecer stock" (mejoras — bloque 1)
-- =============================================================================
-- Nuevo tipo de movimiento para cuando un admin escribe directamente cuál
-- debería ser el stock final. NUNCA se hace UPDATE directo del balance: se
-- calcula la diferencia contra el stock actual y se genera un movimiento
-- auditable como cualquier otro (mismo mecanismo que ventas/ajustes/transferencias).

alter type public.stock_movement_type add value 'ADJUSTMENT_SET';
