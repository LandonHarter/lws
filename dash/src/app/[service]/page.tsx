import { ServiceIndex } from "@/components/service-index";

export default async function ServicePage({
  params,
}: {
  params: Promise<{ service: string }>;
}) {
  const { service } = await params;
  return <ServiceIndex service={service} />;
}
