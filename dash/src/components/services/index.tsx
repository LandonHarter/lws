"use client";

import { serviceMeta } from "@/lib/services";
import { GenericDetail } from "@/components/services/generic";
import {
  DetailProps,
  type ServiceCreateFieldsProps,
} from "@/components/services/shared";
import { SqsCreate, SqsDetail } from "@/components/services/sqs";

export function ServiceDetail(props: DetailProps) {
  switch (serviceMeta(props.service).id) {
    case "sqs":
      return <SqsDetail stats={props.stats} updatedAt={props.updatedAt} />;
    default:
      return <GenericDetail {...props} />;
  }
}

export function ServiceCreateFields({
  service,
  ...props
}: ServiceCreateFieldsProps & { service: string }) {
  switch (serviceMeta(service).id) {
    case "sqs":
      return <SqsCreate {...props} />;
    default:
      return null;
  }
}
