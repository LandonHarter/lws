import { ServiceCreate } from "@/components/service-create";

export default async function ServiceCreatePage({
  params,
}: {
  params: Promise<{ service: string }>;
}) {
  const { service } = await params;
  return <ServiceCreate service={service} />;
}
