import { ResourceDetail } from "@/components/resource-detail";

export default async function ResourcePage({
  params,
}: {
  params: Promise<{ service: string; id: string }>;
}) {
  const { service, id } = await params;
  return <ResourceDetail service={service} id={decodeURIComponent(id)} />;
}
