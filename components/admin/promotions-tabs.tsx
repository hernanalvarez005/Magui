"use client";

import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

export function PromotionsTabs({
  promotionsPanel,
  performancePanel,
}: {
  promotionsPanel: React.ReactNode;
  performancePanel: React.ReactNode;
}) {
  return (
    <Tabs defaultValue="promociones">
      <TabsList>
        <TabsTrigger value="promociones">Promociones</TabsTrigger>
        <TabsTrigger value="rendimiento">Rendimiento</TabsTrigger>
      </TabsList>
      <TabsContent value="promociones">{promotionsPanel}</TabsContent>
      <TabsContent value="rendimiento">{performancePanel}</TabsContent>
    </Tabs>
  );
}
